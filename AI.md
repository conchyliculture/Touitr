# Agent Log

Implementation notes for Touitr, kept out of the README.

## Layout

| Path | Role |
| --- | --- |
| `parse.rb` | Reads the Twitter archive zip, extracts media, resolves `t.co` links, pulls OpenGraph data, writes `posts.json`, one static `post/<id>.html` per tweet, and `index.html` |
| `lib/utils.rb` | Shared helpers (url joining, mime detection, number/date formatting) plus a `ProgressBar` logger shim |
| `templates/*.mustache` | Rendered twice: server side by `parse.rb` (Ruby Mustache) for the static pages, and client side by `assets/mustache.js` for the lazy loaded timeline |
| `assets/script.js` | The timeline: loads `posts.json`, filters it, renders pages of posts on scroll |
| `assets/styles.css` | Everything visual, dark theme only |

`post.mustache` is inlined into the generated `script.js` by `generate_scriptjs`, which substitutes
`PLACEHOLDER_POST_TEMPLATE`, `PLACEHOLDER_BASE_URL` and `PLACEHOLDER_TWITTER_HOST`. So the same template
has to stay renderable by both Mustache implementations, and the view data built in `generate_post_file`
(Ruby) has to mirror the one built in `createPostHTML` (JS).

## Advanced search

Client side only: everything runs against the `allPosts` array parsed from `posts.json`, no extra
request and no build step. `templates/index.mustache` holds the UI, `assets/script.js` the logic.

### Filter state

Three variables next to `searchQuery`:

```js
let mediaOnly = false;   // "Only posts with media" checkbox
let fromDate = null;     // Date at 00:00:00.000 local, or null
let untilDate = null;    // Date at 23:59:59.999 local, or null
```

`readAdvancedFilters()` reads the panel inputs back into them and calls `applyFilters()`, which rebuilds
`filteredPosts` from `allPosts` by ANDing every active predicate, then resets and redraws the timeline.
The text query is one of those predicates, so filters and search stack instead of overriding each other.

Details worth keeping:

* **Has media** is `post.media && post.media.length > 0`. `parse.rb` only sets `media` when the tweet has
  `extended_entities`, and types are `photo` or `video` (animated gifs are stored as `video`), so an
  empty array means no media and is correctly excluded.
* **Dates** come from `<input type="date">`, always `YYYY-MM-DD`. `parseDateInput()` builds a *local*
  `Date`, matching `parseTimestamp()` which also builds local dates out of the archive's
  `Mon Nov 03 20:07:11 +0000 2025` strings (it ignores the offset). Both ends are inclusive: `from` snaps
  to the start of its day, `until` to `23:59:59.999`, so picking the same day twice keeps that day.
* A partial or malformed date value yields `null` rather than an `Invalid Date`, otherwise typing into
  the field would blank the timeline mid keystroke.
* `filterFrom.max` / `filterUntil.min` are kept in sync so the picker discourages a backwards range.

### Stale page guard

`loadPosts()` appends a page after a 500ms `setTimeout`. Changing a filter during that window used to
append posts belonging to the previous filter set to the freshly cleared timeline. A `loadToken` counter
is bumped by `applyFilters()`, captured before the timeout, and compared inside it, so a page whose
filters have moved on is dropped.

### Empty state

`noResults` now shows when `searchQuery` **or** any advanced filter is active and nothing matched, rather
than for the text query alone.

## Testing the timeline JS

There is no browser here. `assets/script.js` is plain script (no modules, no imports), so it can be
concatenated with a small DOM shim and exercised under `qjs` (quickjs): stub `document.getElementById`,
`IntersectionObserver`, `Mustache.render`, `fetch` and `setTimeout`, assign `allPosts` directly, then
call `readAdvancedFilters()` / `applyFilters()` and assert on `filteredPosts`. The Ruby side has real
tests in `tests/test_utils.rb`, run with `rake`.

## Known rough edges

* `createPostHTML()` in `assets/script.js` references `joinUrl(baseUrl, ...)` for `avatar_url`, which are
  not defined (the real ones are `join_url` / `base_url`). It never throws today because `parse.rb` writes
  `avatar` from `@archive_owner['avatar']`, a key it never sets, so the value is always null and the
  ternary short circuits. Timeline avatars are therefore always empty, while the static post pages get a
  real avatar from `generate_post_file`.
* `templates/index.mustache` used to close a `</header>` that was never opened, so none of the `.header`
  styles (padding, sticky positioning, bottom border) applied on the index page. The opening tag is back.
