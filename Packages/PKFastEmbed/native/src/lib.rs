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
    if bytes.is_null() && length > 0 {
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

fn run_inference<T>(operation: impl FnOnce() -> anyhow::Result<T>) -> anyhow::Result<T> {
    match std::panic::catch_unwind(AssertUnwindSafe(operation)) {
        Ok(result) => result,
        Err(_) => anyhow::bail!("Model inference panicked."),
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

    match load_model(&path) {
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
}

#[no_mangle]
pub extern "C" fn pkfe_model_dimensions(
    model: *const Model,
    out_dimensions: *mut size_t,
    out_error_message: *mut *mut c_char,
) -> Status {
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

    let embeddings = match run_inference(|| guard.embed(vec![text], None)) {
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

    let embeddings = match run_inference(|| guard.embed(decoded, None)) {
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
    fn panic_is_contained() {
        let result = run_inference(|| -> anyhow::Result<()> {
            std::panic::resume_unwind(Box::new("boom"));
        });

        assert!(result.is_err());
    }
}
