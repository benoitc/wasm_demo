wit_bindgen::generate!({ world: "text" });

use demo::text::host::stop_word;
use exports::demo::text::words::{Count, Guest, GuestTally};
use std::cell::RefCell;
use std::collections::HashMap;

struct Text;

impl Guest for Text {
    type Tally = Tally;

    fn shout(input: String) -> Result<String, String> {
        if input.trim().is_empty() {
            Err("nothing to shout".to_string())
        } else {
            Ok(format!("{}!", input.to_uppercase()))
        }
    }
}

pub struct Tally {
    seen: RefCell<HashMap<String, u32>>,
}

impl GuestTally for Tally {
    fn new() -> Self {
        Tally { seen: RefCell::new(HashMap::new()) }
    }

    // Counts the words the host does not call stop words, and returns how
    // many distinct words the tally holds.
    fn add(&self, text: String) -> u32 {
        let mut seen = self.seen.borrow_mut();
        for w in text.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()) {
            let w = w.to_lowercase();
            if !stop_word(&w) {
                *seen.entry(w).or_insert(0) += 1;
            }
        }
        seen.len() as u32
    }

    fn top(&self, n: u32) -> Vec<Count> {
        let mut all: Vec<Count> = self
            .seen
            .borrow()
            .iter()
            .map(|(w, &n)| Count { word: w.clone(), n })
            .collect();
        all.sort_by(|a, b| b.n.cmp(&a.n).then_with(|| a.word.cmp(&b.word)));
        all.truncate(n as usize);
        all
    }
}

export!(Text);
