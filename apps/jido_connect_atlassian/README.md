# Jido Connect Atlassian

`jido_connect_atlassian` holds Atlassian Document Format (ADF) support that
the `jido_connect_jira` and `jido_connect_confluence` packages share.

It is a library, not a product connector. It declares no provider, actions or
triggers, and it makes no HTTP requests.

## Installation

```elixir
def deps do
  [
    {:jido_connect_atlassian, "~> 0.8"}
  ]
end
```

Most host applications depend on `jido_connect_jira` or
`jido_connect_confluence` instead, which pull this package in.

## ADF to text

`Jido.Connect.Atlassian.ADF.to_text/1` is the strict rendering that the
Confluence package used before this package existed. It fails the whole
document with `:error` on any node or text mark outside its supported subset
and on links that are not HTTPS. `Jido.Connect.Confluence.ADF` delegates to it
unchanged.

## Markdown to ADF

`Jido.Connect.Atlassian.ADF.from_markdown/2` converts bounded Markdown into a
fixed ADF v1 subset for paragraphs, headings, lists, block quotes, fenced code,
hard line breaks, horizontal rules and HTTPS links. Option `:max_length` bounds
the input; the default is 100,000 characters.

## Quality checks

Run from this package directory:

```sh
mix quality
```
