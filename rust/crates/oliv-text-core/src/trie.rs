//! Compact read-only character trie (pythainlp `Trie`), also used as the word set.

pub struct Trie {
    /// Per node: is a word end, first edge index, edge count.
    nodes: Vec<(bool, u32, u32)>,
    /// Edges sorted by char within each node.
    edges: Vec<(char, u32)>,
    count: usize,
}

impl Trie {
    /// Like pythainlp `Trie(words)`: each word is `strip()`ped, duplicates collapse.
    pub fn new<'a>(words: impl IntoIterator<Item = &'a str>) -> Self {
        let mut ws: Vec<Vec<char>> = words
            .into_iter()
            .map(|w| crate::pyu::strip(w).chars().collect())
            .collect();
        ws.sort_unstable();
        ws.dedup();
        let mut t = Trie {
            nodes: vec![(false, 0, 0)],
            edges: Vec::new(),
            count: 0,
        };
        t.build(0, &ws, 0);
        t.count = ws.len();
        t
    }

    fn build(&mut self, node: usize, words: &[Vec<char>], depth: usize) {
        let mut rest = words;
        if rest.first().is_some_and(|w| w.len() == depth) {
            self.nodes[node].0 = true;
            rest = &rest[1..];
        }
        // Group the remaining words (sorted, all longer than `depth`) by next char.
        let mut groups: Vec<(char, &[Vec<char>])> = Vec::new();
        let mut i = 0;
        while i < rest.len() {
            let c = rest[i][depth];
            let mut j = i + 1;
            while j < rest.len() && rest[j][depth] == c {
                j += 1;
            }
            groups.push((c, &rest[i..j]));
            i = j;
        }
        let first = self.edges.len() as u32;
        self.nodes[node].1 = first;
        self.nodes[node].2 = groups.len() as u32;
        let mut children = Vec::with_capacity(groups.len());
        for (c, _) in &groups {
            let child = self.nodes.len() as u32;
            self.nodes.push((false, 0, 0));
            self.edges.push((*c, child));
            children.push(child);
        }
        for ((_, g), child) in groups.into_iter().zip(children) {
            self.build(child as usize, g, depth + 1);
        }
    }

    fn child(&self, node: u32, c: char) -> Option<u32> {
        let (_, first, n) = self.nodes[node as usize];
        let edges = &self.edges[first as usize..(first + n) as usize];
        edges
            .binary_search_by(|e| e.0.cmp(&c))
            .ok()
            .map(|i| edges[i].1)
    }

    /// Lengths (in chars) of every word that is a prefix of `text[start..]`, shortest first.
    pub fn prefixes(&self, text: &[char], start: usize) -> Vec<usize> {
        let mut res = Vec::new();
        let mut cur = 0u32;
        for (i, &c) in text[start..].iter().enumerate() {
            match self.child(cur, c) {
                Some(n) => {
                    if self.nodes[n as usize].0 {
                        res.push(i + 1);
                    }
                    cur = n;
                }
                None => break,
            }
        }
        res
    }

    pub fn contains(&self, word: &str) -> bool {
        let mut cur = 0u32;
        for c in word.chars() {
            match self.child(cur, c) {
                Some(n) => cur = n,
                None => return false,
            }
        }
        self.nodes[cur as usize].0
    }

    pub fn len(&self) -> usize {
        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }
}
