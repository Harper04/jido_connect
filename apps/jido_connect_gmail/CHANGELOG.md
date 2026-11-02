# Changelog

## Unreleased

- Require `gmail.readonly`, or an already granted `gmail.modify` or
  `https://mail.google.com/`, for `google.gmail.messages.list` and
  `google.gmail.threads.list` with a non-blank `query`. Gmail rejects `q`
  under `gmail.metadata`; list requests without a query still run with it.

## 0.1.0

- Initial Gmail provider package scaffold.
