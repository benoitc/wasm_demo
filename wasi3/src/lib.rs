//! A WASI 0.3 command. `run` is an `async func`: it reads standard input as a
//! stream, upper-cases each chunk as it arrives, and writes it to a stream that
//! standard output reads from. Nothing is read whole first.
wit_bindgen::generate!({ world: "upper", path: "wit", generate_all });

use wasi::cli::{stdin, stdout};
use wit_bindgen::StreamResult;

struct Upper;

impl exports::wasi::cli::run::Guest for Upper {
    async fn run() -> Result<(), ()> {
        let (mut input, read_done) = stdin::read_via_stream();
        let (mut output, to_stdout) = wit_stream::new();
        // The host starts reading `to_stdout` now, while this task writes it.
        let written = stdout::write_via_stream(to_stdout);
        loop {
            let (status, chunk) = input.read(Vec::with_capacity(4096)).await;
            if !chunk.is_empty() && !output.write_all(chunk.to_ascii_uppercase()).await.is_empty() {
                return Err(());
            }
            if !matches!(status, StreamResult::Complete(_)) {
                break;
            }
        }
        // Dropping the writer ends standard output's stream.
        drop(output);
        read_done.await.map_err(|_| ())?;
        written.await.map_err(|_| ())
    }
}

export!(Upper);
