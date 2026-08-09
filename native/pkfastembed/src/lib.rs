use fastembed::{
    InitOptionsUserDefined, Pooling, QuantizationMode, TextEmbedding, TokenizerFiles,
    UserDefinedEmbeddingModel,
};
use libc::{c_char, size_t};
use std::ffi::{CStr, CString};
use std::fs;
use std::path::{Path, PathBuf};
use std::ptr;
use std::panic::AssertUnwindSafe;
use std::slice;
use std::sync::Mutex;

const DIMENSIONS: usize = 384;
const ABI_VERSION: u32 = 1;
const MAX_TEXT_COUNT: usize = 64;
const MAX_BYTES_PER_TEXT: usize = 65_536;
const MAX_TOTAL_BATCH_BYTES: usize = 262_144;

pub struct Model {
    inner: Mutex<TextEmbedding>,
    dimensions: usize,
}

#[repr(C)]
pub enum Status {
    Ok = 0,
    InvalidArgument = 1,
    InvalidUtf8 = 2,
    ModelLoadFailed = 3,
    InferenceFailed = 4,
    BufferTooSmall = 5,
    AbiMismatch = 6,
}

fn set_error(target: *mut *mut c_char, message: impl Into<String>) {
    if target.is_null() {
        return;
    }

    let sanitized = message.into().replace('\0', " ");
    if let Ok(value) = CString::new(sanitized) {
        unsafe {
            *target = value.into_raw();
        }
    }
}

fn clear_error(target: *mut *mut c_char) {
    if target.is_null() {
        return;
    }

    unsafe {
        *target = ptr::null_mut();
    }
}

fn required_file(directory: &Path, name: &str) -> anyhow::Result<Vec<u8>> {
    let path = directory.join(name);
    fs::read(&path).map_err(|error| anyhow::anyhow!("Failed to read {}: {}", path.display(), error))
}

fn load_model(directory: &Path) -> anyhow::Result<Model> {
    let tokenizer_files = TokenizerFiles {
        tokenizer_file: required_file(directory, "tokenizer.json")?,
        config_file: required_file(directory, "config.json")?,
        special_tokens_map_file: required_file(directory, "special_tokens_map.json")?,
        tokenizer_config_file: required_file(directory, "tokenizer_config.json")?,
    };

    let user_model = UserDefinedEmbeddingModel::new(required_file(directory, "model.onnx")?, tokenizer_files)
        .with_pooling(Pooling::Mean)
        .with_quantization(QuantizationMode::None);

    let embedding = TextEmbedding::try_new_from_user_defined(user_model, InitOptionsUserDefined::default())?;
    Ok(Model {
        inner: Mutex::new(embedding),
        dimensions: DIMENSIONS,
    })
}

fn with_model<'a>(model: *mut Model) -> anyhow::Result<&'a Model> {
    if model.is_null() {
        anyhow::bail!("Model handle was null.")
    }
    Ok(unsafe { &*model })
}

fn decode_text(bytes: *const u8, length: usize) -> anyhow::Result<String> {
    if length == 0 {
        return Ok(String::new());
    }

    if bytes.is_null() {
        anyhow::bail!("Input bytes were null.")
    }

    let data = unsafe { slice::from_raw_parts(bytes, length) };
    Ok(std::str::from_utf8(data)?.to_owned())
}

fn checked_output_count(dimensions: usize, text_count: usize) -> anyhow::Result<usize> {
    dimensions
        .checked_mul(text_count)
        .ok_or_else(|| anyhow::anyhow!("Requested output size overflowed usize."))
}

fn validate_single_input_budget(byte_count: usize) -> anyhow::Result<()> {
    anyhow::ensure!(
        byte_count <= MAX_BYTES_PER_TEXT,
        "Embedding input exceeded the per-text byte limit of {} bytes ({} bytes provided).",
        MAX_BYTES_PER_TEXT,
        byte_count
    );
    anyhow::ensure!(
        byte_count <= MAX_TOTAL_BATCH_BYTES,
        "Embedding input exceeded the total batch byte limit of {} bytes ({} bytes provided).",
        MAX_TOTAL_BATCH_BYTES,
        byte_count
    );
    Ok(())
}

fn validate_batch_input_budget(text_count: usize, lengths: &[usize]) -> anyhow::Result<()> {
    anyhow::ensure!(
        text_count <= MAX_TEXT_COUNT,
        "Embedding input exceeded the batch text-count limit of {} item(s) ({} provided).",
        MAX_TEXT_COUNT,
        text_count
    );
    anyhow::ensure!(
        text_count == lengths.len(),
        "Embedding batch length metadata expected {} item(s) but received {}.",
        text_count,
        lengths.len()
    );

    let mut total_bytes = 0usize;
    for &byte_count in lengths {
        validate_single_input_budget(byte_count)?;
        total_bytes = total_bytes
            .checked_add(byte_count)
            .ok_or_else(|| anyhow::anyhow!(
                "Embedding input exceeded the total batch byte limit of {} bytes (overflow while summing lengths).",
                MAX_TOTAL_BATCH_BYTES
            ))?;
        anyhow::ensure!(
            total_bytes <= MAX_TOTAL_BATCH_BYTES,
            "Embedding input exceeded the total batch byte limit of {} bytes ({} bytes provided).",
            MAX_TOTAL_BATCH_BYTES,
            total_bytes
        );
    }

    Ok(())
}

fn contain_panics<T>(
    context: &'static str,
    operation: impl FnOnce() -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    match std::panic::catch_unwind(AssertUnwindSafe(operation)) {
        Ok(result) => result,
        Err(_) => anyhow::bail!("{context} panicked."),
    }
}

fn c_abi_guard(
    context: &'static str,
    out_error_message: *mut *mut c_char,
    panic_status: Status,
    operation: impl FnOnce() -> Status,
) -> Status {
    match std::panic::catch_unwind(AssertUnwindSafe(operation)) {
        Ok(status) => status,
        Err(_) => {
            set_error(out_error_message, format!("{context} panicked."));
            panic_status
        }
    }
}

fn write_single_embedding(
    out_buffer: &mut [f32],
    embeddings: &[Vec<f32>],
    dimensions: usize,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        embeddings.len() == 1,
        "Expected exactly 1 embedding, got {}.",
        embeddings.len()
    );

    let embedding = &embeddings[0];
    anyhow::ensure!(
        embedding.len() == dimensions,
        "Expected embedding length {}, got {}.",
        dimensions,
        embedding.len()
    );

    out_buffer.copy_from_slice(embedding);
    Ok(())
}

fn write_batch_embeddings(
    out_buffer: &mut [f32],
    embeddings: &[Vec<f32>],
    dimensions: usize,
    text_count: usize,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        embeddings.len() == text_count,
        "Expected {} embeddings, got {}.",
        text_count,
        embeddings.len()
    );

    for (index, embedding) in embeddings.iter().enumerate() {
        anyhow::ensure!(
            embedding.len() == dimensions,
            "Expected embedding {} to contain {} values, got {}.",
            index,
            dimensions,
            embedding.len()
        );
    }

    for (index, embedding) in embeddings.iter().enumerate() {
        let start = index
            .checked_mul(dimensions)
            .ok_or_else(|| anyhow::anyhow!("Output offset overflowed usize."))?;
        out_buffer[start..start + dimensions].copy_from_slice(embedding);
    }

    Ok(())
}

#[no_mangle]
pub extern "C" fn pkfe_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn pkfe_model_create(
    model_directory: *const c_char,
    out_model: *mut *mut Model,
    out_error_message: *mut *mut c_char,
) -> Status {
    c_abi_guard(
        "Model creation",
        out_error_message,
        Status::ModelLoadFailed,
        || {
            clear_error(out_error_message);

            if model_directory.is_null() || out_model.is_null() {
                set_error(out_error_message, "model_directory and out_model are required.");
                return Status::InvalidArgument;
            }

            let path = unsafe { CStr::from_ptr(model_directory) };
            let path = match path.to_str() {
                Ok(value) => PathBuf::from(value),
                Err(error) => {
                    set_error(out_error_message, format!("model_directory was not valid UTF-8: {error}"));
                    return Status::InvalidUtf8;
                }
            };

            match contain_panics("Model creation", || load_model(&path)) {
                Ok(model) => {
                    unsafe {
                        *out_model = Box::into_raw(Box::new(model));
                    }
                    Status::Ok
                }
                Err(error) => {
                    set_error(out_error_message, error.to_string());
                    Status::ModelLoadFailed
                }
            }
        },
    )
}

#[no_mangle]
pub extern "C" fn pkfe_model_dimensions(
    model: *const Model,
    out_dimensions: *mut size_t,
    out_error_message: *mut *mut c_char,
) -> Status {
    c_abi_guard(
        "Model dimension query",
        out_error_message,
        Status::InvalidArgument,
        || {
            clear_error(out_error_message);

            if out_dimensions.is_null() {
                set_error(out_error_message, "out_dimensions is required.");
                return Status::InvalidArgument;
            }

            let model = match with_model(model.cast_mut()) {
                Ok(model) => model,
                Err(error) => {
                    set_error(out_error_message, error.to_string());
                    return Status::InvalidArgument;
                }
            };

            unsafe {
                *out_dimensions = model.dimensions;
            }
            Status::Ok
        },
    )
}

#[no_mangle]
pub extern "C" fn pkfe_model_embed(
    model: *mut Model,
    utf8_bytes: *const u8,
    utf8_length: size_t,
    out_buffer: *mut f32,
    out_count: size_t,
    out_error_message: *mut *mut c_char,
) -> Status {
    c_abi_guard(
        "Model inference",
        out_error_message,
        Status::InferenceFailed,
        || {
            clear_error(out_error_message);

            let model = match with_model(model) {
                Ok(model) => model,
                Err(error) => {
                    set_error(out_error_message, error.to_string());
                    return Status::InvalidArgument;
                }
            };

            if out_buffer.is_null() {
                set_error(out_error_message, "out_buffer is required.");
                return Status::InvalidArgument;
            }

            if out_count < model.dimensions {
                set_error(out_error_message, format!("out_buffer capacity {} was smaller than {}", out_count, model.dimensions));
                return Status::BufferTooSmall;
            }

            if let Err(error) = validate_single_input_budget(utf8_length) {
                set_error(out_error_message, error.to_string());
                return Status::InvalidArgument;
            }

            let text = match decode_text(utf8_bytes, utf8_length) {
                Ok(text) => text,
                Err(error) => {
                    set_error(out_error_message, error.to_string());
                    return Status::InvalidUtf8;
                }
            };

            let mut guard = match model.inner.lock() {
                Ok(guard) => guard,
                Err(_) => {
                    set_error(out_error_message, "The model mutex was poisoned.");
                    return Status::InferenceFailed;
                }
            };

            let embeddings = match contain_panics("Model inference", || guard.embed(vec![text], None)) {
                Ok(embeddings) => embeddings,
                Err(error) => {
                    set_error(out_error_message, error.to_string());
                    return Status::InferenceFailed;
                }
            };

            let output = unsafe { slice::from_raw_parts_mut(out_buffer, model.dimensions) };
            match write_single_embedding(output, &embeddings, model.dimensions) {
                Ok(()) => Status::Ok,
                Err(error) => {
                    set_error(out_error_message, error.to_string());
                    Status::InferenceFailed
                }
            }
        },
    )
}

#[no_mangle]
pub extern "C" fn pkfe_model_embed_batch(
    model: *mut Model,
    utf8_bytes: *const *const u8,
    utf8_lengths: *const size_t,
    text_count: size_t,
    out_buffer: *mut f32,
    out_count: size_t,
    out_error_message: *mut *mut c_char,
) -> Status {
    c_abi_guard(
        "Model inference",
        out_error_message,
        Status::InferenceFailed,
        || {
            clear_error(out_error_message);

            let model = match with_model(model) {
                Ok(model) => model,
                Err(error) => {
                    set_error(out_error_message, error.to_string());
                    return Status::InvalidArgument;
                }
            };

            if text_count == 0 {
                return Status::Ok;
            }

            if utf8_bytes.is_null() || utf8_lengths.is_null() || out_buffer.is_null() {
                set_error(out_error_message, "utf8_bytes, utf8_lengths, and out_buffer are required.");
                return Status::InvalidArgument;
            }

            let expected = match checked_output_count(model.dimensions, text_count) {
                Ok(expected) => expected,
                Err(error) => {
                    set_error(out_error_message, error.to_string());
                    return Status::InvalidArgument;
                }
            };

            if out_count < expected {
                set_error(out_error_message, format!("out_buffer capacity {} was smaller than {}", out_count, expected));
                return Status::BufferTooSmall;
            }

            let inputs = unsafe { slice::from_raw_parts(utf8_bytes, text_count) };
            let lengths = unsafe { slice::from_raw_parts(utf8_lengths, text_count) };
            if let Err(error) = validate_batch_input_budget(text_count, lengths) {
                set_error(out_error_message, error.to_string());
                return Status::InvalidArgument;
            }

            let mut decoded = Vec::with_capacity(text_count);
            for (bytes, length) in inputs.iter().zip(lengths) {
                match decode_text(*bytes, *length) {
                    Ok(text) => decoded.push(text),
                    Err(error) => {
                        set_error(out_error_message, error.to_string());
                        return Status::InvalidUtf8;
                    }
                }
            }

            let mut guard = match model.inner.lock() {
                Ok(guard) => guard,
                Err(_) => {
                    set_error(out_error_message, "The model mutex was poisoned.");
                    return Status::InferenceFailed;
                }
            };

            let embeddings = match contain_panics("Model inference", || guard.embed(decoded, None)) {
                Ok(embeddings) => embeddings,
                Err(error) => {
                    set_error(out_error_message, error.to_string());
                    return Status::InferenceFailed;
                }
            };

            let output = unsafe { slice::from_raw_parts_mut(out_buffer, expected) };
            match write_batch_embeddings(output, &embeddings, model.dimensions, text_count) {
                Ok(()) => Status::Ok,
                Err(error) => {
                    set_error(out_error_message, error.to_string());
                    Status::InferenceFailed
                }
            }
        },
    )
}

#[no_mangle]
pub extern "C" fn pkfe_model_destroy(model: *mut Model) {
    if model.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(model));
    }
}

#[no_mangle]
pub extern "C" fn pkfe_string_destroy(value: *mut c_char) {
    if value.is_null() {
        return;
    }

    unsafe {
        drop(CString::from_raw(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sentinel_buffer(len: usize) -> Vec<f32> {
        vec![99.0; len]
    }

    #[test]
    fn decode_text_accepts_null_for_empty_input() {
        assert_eq!(decode_text(ptr::null(), 0).unwrap(), "");
    }

    #[test]
    fn single_writer_rejects_empty_output_without_mutating_buffer() {
        let mut buffer = sentinel_buffer(4);

        let result = write_single_embedding(&mut buffer, &[], 4);

        assert!(result.is_err());
        assert_eq!(buffer, sentinel_buffer(4));
    }

    #[test]
    fn single_writer_rejects_too_many_embeddings_without_mutating_buffer() {
        let mut buffer = sentinel_buffer(4);
        let embeddings = vec![vec![1.0, 2.0, 3.0], vec![4.0, 5.0, 6.0]];

        let result = write_single_embedding(&mut buffer, &embeddings, 3);

        assert!(result.is_err());
        assert_eq!(buffer, sentinel_buffer(4));
    }

    #[test]
    fn single_writer_rejects_short_embedding_without_mutating_buffer() {
        let mut buffer = sentinel_buffer(4);
        let embeddings = vec![vec![1.0, 2.0, 3.0]];

        let result = write_single_embedding(&mut buffer, &embeddings, 4);

        assert!(result.is_err());
        assert_eq!(buffer, sentinel_buffer(4));
    }

    #[test]
    fn single_writer_rejects_long_embedding_without_mutating_buffer() {
        let mut buffer = sentinel_buffer(2);
        let embeddings = vec![vec![1.0, 2.0, 3.0]];

        let result = write_single_embedding(&mut buffer, &embeddings, 2);

        assert!(result.is_err());
        assert_eq!(buffer, sentinel_buffer(2));
    }

    #[test]
    fn batch_writer_rejects_too_few_embeddings_without_mutating_buffer() {
        let mut buffer = sentinel_buffer(6);
        let embeddings = vec![vec![1.0, 2.0, 3.0]];

        let result = write_batch_embeddings(&mut buffer, &embeddings, 3, 2);

        assert!(result.is_err());
        assert_eq!(buffer, sentinel_buffer(6));
    }

    #[test]
    fn batch_writer_rejects_too_many_embeddings_without_mutating_buffer() {
        let mut buffer = sentinel_buffer(6);
        let embeddings = vec![
            vec![1.0, 2.0, 3.0],
            vec![4.0, 5.0, 6.0],
            vec![7.0, 8.0, 9.0],
        ];

        let result = write_batch_embeddings(&mut buffer, &embeddings, 3, 2);

        assert!(result.is_err());
        assert_eq!(buffer, sentinel_buffer(6));
    }

    #[test]
    fn batch_writer_rejects_short_embedding_without_mutating_buffer() {
        let mut buffer = sentinel_buffer(6);
        let embeddings = vec![vec![1.0, 2.0], vec![4.0, 5.0, 6.0]];

        let result = write_batch_embeddings(&mut buffer, &embeddings, 3, 2);

        assert!(result.is_err());
        assert_eq!(buffer, sentinel_buffer(6));
    }

    #[test]
    fn batch_writer_rejects_long_embedding_without_mutating_buffer() {
        let mut buffer = sentinel_buffer(6);
        let embeddings = vec![vec![1.0, 2.0, 3.0], vec![4.0, 5.0, 6.0, 7.0]];

        let result = write_batch_embeddings(&mut buffer, &embeddings, 3, 2);

        assert!(result.is_err());
        assert_eq!(buffer, sentinel_buffer(6));
    }

    #[test]
    fn batch_output_count_overflow_is_rejected() {
        assert!(checked_output_count(usize::MAX, 2).is_err());
    }

    #[test]
    fn single_input_budget_rejects_texts_over_the_byte_limit() {
        let result = validate_single_input_budget(65_537);

        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("per-text byte limit")
        );
    }

    #[test]
    fn batch_input_budget_rejects_batches_over_the_text_count_limit() {
        let lengths = vec![1; 65];

        let result = validate_batch_input_budget(lengths.len(), &lengths);

        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("batch text-count limit")
        );
    }

    #[test]
    fn batch_input_budget_rejects_batches_over_the_total_byte_limit() {
        let lengths = vec![65_536; 5];

        let result = validate_batch_input_budget(lengths.len(), &lengths);

        assert!(result.is_err());
        assert!(
            result
                .unwrap_err()
                .to_string()
                .contains("total batch byte limit")
        );
    }

    #[test]
    fn panic_is_contained() {
        let result = contain_panics("Test", || -> anyhow::Result<()> {
            std::panic::resume_unwind(Box::new("boom"));
        });

        assert!(result.is_err());
    }

    #[test]
    fn c_abi_guard_converts_panics_into_stable_failure() {
        let mut error_message: *mut c_char = std::ptr::null_mut();

        let status = c_abi_guard(
            "Test boundary",
            &mut error_message,
            Status::InferenceFailed,
            || -> Status { panic!("boom") },
        );

        assert_eq!(status as u32, Status::InferenceFailed as u32);
        assert!(!error_message.is_null());
        let message = unsafe { std::ffi::CStr::from_ptr(error_message) }
            .to_string_lossy()
            .into_owned();
        assert_eq!(message, "Test boundary panicked.");

        pkfe_string_destroy(error_message);
    }
}
