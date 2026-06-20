use fastembed::{
    InitOptionsUserDefined, Pooling, QuantizationMode, TextEmbedding, TokenizerFiles,
    UserDefinedEmbeddingModel,
};
use libc::{c_char, size_t};
use std::ffi::{CStr, CString};
use std::fs;
use std::path::{Path, PathBuf};
use std::ptr;
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

    match guard.embed(vec![text], None) {
        Ok(mut embeddings) => {
            let embedding = embeddings.remove(0);
            unsafe {
                ptr::copy_nonoverlapping(embedding.as_ptr(), out_buffer, model.dimensions);
            }
            Status::Ok
        }
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

    let expected = model.dimensions * text_count;
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

    match guard.embed(decoded, None) {
        Ok(embeddings) => {
            let flattened: Vec<f32> = embeddings.into_iter().flatten().collect();
            unsafe {
                ptr::copy_nonoverlapping(flattened.as_ptr(), out_buffer, expected);
            }
            Status::Ok
        }
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
