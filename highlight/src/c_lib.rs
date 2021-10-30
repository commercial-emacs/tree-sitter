use super::{Error, Highlight, HighlightConfiguration, HighlightEvent, Highlighter, HtmlRenderer};
use regex::Regex;
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::process::abort;
use std::sync::atomic::AtomicUsize;
use std::{fmt, slice, str};
use tree_sitter::Language;
use tree_sitter::Node;

#[repr(C)]
pub enum HighlightEventType {
    HighlightEnd = -2,
    Source = -1,
    HighlightStartMinimum = 0,
}

#[repr(C)]
#[derive(Copy, Clone)]
pub struct TSHighlightEvent {
    start: u32,
    end: u32,
    index: i32,
}

#[repr(C)]
pub struct TSHighlightEventSlice {
    arr: *mut TSHighlightEvent,
    len: u32,
}

#[repr(C)]
pub struct TSHighlighter {
    languages: HashMap<String, (Option<Regex>, HighlightConfiguration)>,
    attribute_strings: Vec<&'static [u8]>,
    highlight_names: Vec<String>,
    carriage_return_index: Option<usize>,
}

#[repr(C)]
pub struct TSHighlightBuffer {
    highlighter: Highlighter,
    renderer: HtmlRenderer,
}

#[repr(C)]
pub enum ErrorCode {
    Ok,
    UnknownScope,
    Timeout,
    InvalidLanguage,
    InvalidUtf8,
    InvalidRegex,
    InvalidQuery,
}

#[no_mangle]
pub extern "C" fn ts_highlighter_new(
    highlight_names: *const *const c_char,
    attribute_strings: *const *const c_char,
    highlight_count: u32,
) -> *mut TSHighlighter {
    let highlight_names =
        unsafe { slice::from_raw_parts(highlight_names, highlight_count as usize) };
    let attribute_strings =
        unsafe { slice::from_raw_parts(attribute_strings, highlight_count as usize) };
    let highlight_names = highlight_names
        .into_iter()
        .map(|s| unsafe { CStr::from_ptr(*s).to_string_lossy().to_string() })
        .collect::<Vec<_>>();
    let attribute_strings = attribute_strings
        .into_iter()
        .map(|s| unsafe { CStr::from_ptr(*s).to_bytes() })
        .collect();
    let carriage_return_index = highlight_names.iter().position(|s| s == "carriage-return");
    Box::into_raw(Box::new(TSHighlighter {
        languages: HashMap::new(),
        attribute_strings,
        highlight_names,
        carriage_return_index,
    }))
}

#[no_mangle]
pub extern "C" fn ts_highlighter_add_language(
    this: *mut TSHighlighter,
    scope_name: *const c_char,
    injection_regex: *const c_char,
    language: Language,
    highlight_query: *const c_char,
    injection_query: *const c_char,
    locals_query: *const c_char,
    highlight_query_len: u32,
    injection_query_len: u32,
    locals_query_len: u32,
) -> ErrorCode {
    let f = move || {
        let this = unwrap_mut_ptr(this);
        let scope_name = unsafe { CStr::from_ptr(scope_name) };
        let scope_name = scope_name
            .to_str()
            .or(Err(ErrorCode::InvalidUtf8))?
            .to_string();
        let injection_regex = if injection_regex.is_null() {
            None
        } else {
            let pattern = unsafe { CStr::from_ptr(injection_regex) };
            let pattern = pattern.to_str().or(Err(ErrorCode::InvalidUtf8))?;
            Some(Regex::new(pattern).or(Err(ErrorCode::InvalidRegex))?)
        };

        let highlight_query = unsafe {
            slice::from_raw_parts(highlight_query as *const u8, highlight_query_len as usize)
        };
        let highlight_query = str::from_utf8(highlight_query).or(Err(ErrorCode::InvalidUtf8))?;

        let injection_query = if injection_query_len > 0 {
            let query = unsafe {
                slice::from_raw_parts(injection_query as *const u8, injection_query_len as usize)
            };
            str::from_utf8(query).or(Err(ErrorCode::InvalidUtf8))?
        } else {
            ""
        };

        let locals_query = if locals_query_len > 0 {
            let query = unsafe {
                slice::from_raw_parts(locals_query as *const u8, locals_query_len as usize)
            };
            str::from_utf8(query).or(Err(ErrorCode::InvalidUtf8))?
        } else {
            ""
        };

        let mut config =
            HighlightConfiguration::new(language, highlight_query, injection_query, locals_query)
                .or(Err(ErrorCode::InvalidQuery))?;
        config.configure(&this.highlight_names.as_slice());
        this.languages.insert(scope_name, (injection_regex, config));

        Ok(())
    };

    match f() {
        Ok(()) => ErrorCode::Ok,
        Err(e) => e,
    }
}

#[no_mangle]
pub extern "C" fn ts_highlight_buffer_new() -> *mut TSHighlightBuffer {
    Box::into_raw(Box::new(TSHighlightBuffer {
        highlighter: Highlighter::new(),
        renderer: HtmlRenderer::new(),
    }))
}

#[no_mangle]
pub extern "C" fn ts_highlighter_delete(this: *mut TSHighlighter) {
    drop(unsafe { Box::from_raw(this) })
}

#[no_mangle]
pub extern "C" fn ts_highlight_buffer_delete(this: *mut TSHighlightBuffer) {
    drop(unsafe { Box::from_raw(this) })
}

#[no_mangle]
pub extern "C" fn ts_highlight_buffer_content(this: *const TSHighlightBuffer) -> *const u8 {
    let this = unwrap_ptr(this);
    this.renderer.html.as_slice().as_ptr()
}

#[no_mangle]
pub extern "C" fn ts_highlight_buffer_line_offsets(this: *const TSHighlightBuffer) -> *const u32 {
    let this = unwrap_ptr(this);
    this.renderer.line_offsets.as_slice().as_ptr()
}

#[no_mangle]
pub extern "C" fn ts_highlight_buffer_len(this: *const TSHighlightBuffer) -> u32 {
    let this = unwrap_ptr(this);
    this.renderer.html.len() as u32
}

#[no_mangle]
pub extern "C" fn ts_highlight_buffer_line_count(this: *const TSHighlightBuffer) -> u32 {
    let this = unwrap_ptr(this);
    this.renderer.line_offsets.len() as u32
}

#[no_mangle]
pub extern "C" fn ts_highlighter_return_highlights(
    this: *const TSHighlighter,
    scope_name: *const c_char,
    source_code: *const c_char,
    source_code_len: u32,
    node: &Node,
    output: *mut TSHighlightBuffer,
) -> TSHighlightEventSlice {
    let this = unwrap_ptr(this);
    let output = unwrap_mut_ptr(output);
    let scope_name = unwrap(unsafe { CStr::from_ptr(scope_name).to_str() });
    let source_code =
        unsafe { slice::from_raw_parts(source_code as *const u8, source_code_len as usize) };
    let highlights =
        this.highlight_preparsed(source_code, scope_name, node, &mut output.highlighter);
    let mut ts_highlights = Vec::new();
    if let Ok(highlights) = highlights {
        for event in highlights {
            match event {
                Ok(HighlightEvent::HighlightStart(s)) => {
                    ts_highlights.push(TSHighlightEvent {
                        start: 0,
                        end: 0,
                        index: s.0 as i32,
                    });
                }
                Ok(HighlightEvent::HighlightEnd) => {
                    ts_highlights.push(TSHighlightEvent {
                        start: 0,
                        end: 0,
                        index: HighlightEventType::HighlightEnd as i32,
                    });
                }
                Ok(HighlightEvent::Source { start, end }) => {
                    ts_highlights.push(TSHighlightEvent {
                        start: start as u32,
                        end: end as u32,
                        index: HighlightEventType::Source as i32,
                    });
                }
                Err(_) => (),
            }
        }
    }
    let boxed_slice: Box<[TSHighlightEvent]> = ts_highlights.into_boxed_slice();
    let len = boxed_slice.len() as u32;
    let fat_ptr: *mut [TSHighlightEvent] = Box::into_raw(boxed_slice);
    let slim_ptr: *mut TSHighlightEvent = fat_ptr as _;
    TSHighlightEventSlice { arr: slim_ptr, len }
}

#[no_mangle]
pub unsafe extern "C" fn ts_highlighter_free_highlights(
    TSHighlightEventSlice { arr, len }: TSHighlightEventSlice,
) {
    if !arr.is_null() {
        let slice: &mut [TSHighlightEvent] = slice::from_raw_parts_mut(arr, len as usize);
        drop(Box::from_raw(slice));
    }
}

#[no_mangle]
pub extern "C" fn ts_highlighter_highlight(
    this: *const TSHighlighter,
    scope_name: *const c_char,
    source_code: *const c_char,
    source_code_len: u32,
    output: *mut TSHighlightBuffer,
    cancellation_flag: *const AtomicUsize,
) -> ErrorCode {
    let this = unwrap_ptr(this);
    let output = unwrap_mut_ptr(output);
    let scope_name = unwrap(unsafe { CStr::from_ptr(scope_name).to_str() });
    let source_code =
        unsafe { slice::from_raw_parts(source_code as *const u8, source_code_len as usize) };
    let cancellation_flag = unsafe { cancellation_flag.as_ref() };
    this.highlight(source_code, scope_name, output, cancellation_flag)
}

impl TSHighlighter {
    fn highlight_preparsed<'a>(
        &'a self,
        source_code: &'a [u8],
        scope_name: &'a str,
        node: &'a Node,
        highlighter: &'a mut Highlighter,
    ) -> Result<impl Iterator<Item = Result<HighlightEvent, Error>> + 'a, Error> {
        let entry = self.languages.get(scope_name);
        if entry.is_none() {
            return Err(Error::InvalidLanguage);
        }
        let (_, configuration) = entry.unwrap();
        highlighter.highlight_preparsed(configuration, source_code, node)
    }

    fn highlight_base<'a>(
        &'a self,
        source_code: &'a [u8],
        scope_name: &'a str,
        highlighter: &'a mut Highlighter,
        cancellation_flag: Option<&'a AtomicUsize>,
    ) -> Result<impl Iterator<Item = Result<HighlightEvent, Error>> + 'a, Error> {
        let entry = self.languages.get(scope_name);
        if entry.is_none() {
            return Err(Error::InvalidLanguage);
        }
        let (_, configuration) = entry.unwrap();
        let languages = &self.languages;

        highlighter.highlight(
            configuration,
            source_code,
            cancellation_flag,
            move |injection_string| {
                languages.values().find_map(|(injection_regex, config)| {
                    injection_regex.as_ref().and_then(|regex| {
                        if regex.is_match(injection_string) {
                            Some(config)
                        } else {
                            None
                        }
                    })
                })
            },
        )
    }

    fn highlight(
        &self,
        source_code: &[u8],
        scope_name: &str,
        output: &mut TSHighlightBuffer,
        cancellation_flag: Option<&AtomicUsize>,
    ) -> ErrorCode {
        let highlights = self.highlight_base(
            source_code,
            scope_name,
            &mut output.highlighter,
            cancellation_flag,
        );
        match highlights {
            Err(Error::InvalidLanguage) => ErrorCode::UnknownScope,
            Ok(highlights) => {
                output.renderer.reset();
                output
                    .renderer
                    .set_carriage_return_highlight(self.carriage_return_index.map(Highlight));
                let result = output
                    .renderer
                    .render(highlights, source_code, &|s| self.attribute_strings[s.0]);
                match result {
                    Err(Error::Cancelled) => ErrorCode::Timeout,
                    Err(Error::InvalidLanguage) => ErrorCode::InvalidLanguage,
                    Err(Error::Unknown) => ErrorCode::Timeout,
                    Ok(()) => ErrorCode::Ok,
                }
            }
            _ => ErrorCode::Timeout,
        }
    }
}

fn unwrap_ptr<'a, T>(result: *const T) -> &'a T {
    unsafe { result.as_ref() }.unwrap_or_else(|| {
        eprintln!("{}:{} - pointer must not be null", file!(), line!());
        abort();
    })
}

fn unwrap_mut_ptr<'a, T>(result: *mut T) -> &'a mut T {
    unsafe { result.as_mut() }.unwrap_or_else(|| {
        eprintln!("{}:{} - pointer must not be null", file!(), line!());
        abort();
    })
}

fn unwrap<T, E: fmt::Display>(result: Result<T, E>) -> T {
    result.unwrap_or_else(|error| {
        eprintln!("tree-sitter highlight error: {}", error);
        abort();
    })
}
