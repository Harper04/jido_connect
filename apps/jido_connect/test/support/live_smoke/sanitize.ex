defmodule Jido.Connect.TestSupport.LiveSmoke.LeakError do
  @moduledoc """
  Raised when sanitized live smoke output still holds the value of a
  credential variable or of a configured email address.
  """

  defexception [:variable]

  @impl true
  def message(%__MODULE__{variable: variable}) do
    "live smoke output contains the value of #{variable}; nothing was written"
  end
end

defmodule Jido.Connect.TestSupport.LiveSmoke.Sanitize do
  @moduledoc false

  # Sanitizes recorded responses. One state keeps the placeholders for email
  # addresses, display names and configured fields stable across all values
  # of one recording.

  alias Jido.Connect.Sanitizer
  alias Jido.Connect.TestSupport.LiveSmoke.LeakError

  @email_pattern "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9\\-]+(?:\\.[A-Za-z0-9\\-]+)*\\.[A-Za-z]{2,}"
  # Matching starts only where a local part starts, so a long run of
  # local-part characters is scanned once, not once per position.
  @email Regex.compile!("(?<![A-Za-z0-9._%+\\-])" <> @email_pattern)
  # A value made only of `Name <address>` and bare address entries, as in mail
  # headers. The possessive `*+` keeps long runs of spaces from backtracking.
  @address_list ~r/^\s*+(?:(?:(?:"[^"]*"\s*+|[^"<>,;:]*)<\s*+#{@email_pattern}\s*+>|#{@email_pattern})\s*+(?:,\s*+|$))+$/
  # One entry of such a list; matching starts only at the start of an entry.
  @named_address ~r/(?:^|,)\s*+(?:"([^"]+)"|([^"<>,;:\s][^"<>,;:]*?))\s*+<\s*+(#{@email_pattern})\s*+>/
  @name_keys ~w(displayName display_name display_name_normalized real_name
                real_name_normalized publicName fullName full_name first_name last_name
                givenName familyName username user_name)
  # `x-amz-cf-pop` names the CloudFront edge that served the recording, and
  # so the recorder's location.
  @dropped_header ~r/auth|cookie|token|secret|signature|^x-forwarded-|^forwarded$|^x-real-ip$|^x-amz-cf-pop$/i
  # Placeholders this module writes. Learning them again would number them
  # anew, so they are skipped, and a new value gets a number that no
  # placeholder in the input holds.
  @email_placeholder ~r/^person-\d+@example\.com$/
  @name_placeholder ~r/^Person \d+$/
  @placeholder ~r/person-\d+@example\.com|Person \d+/
  # Email addresses and name placeholders, the parts of a text that names are
  # never replaced in, so a learned name such as "Person" or "example.com"
  # leaves addresses and placeholders whole. `<field>-<n>` placeholders of
  # the configured fields join them per state.
  @token "(?<![A-Za-z0-9._%+\\-])#{@email_pattern}|(?<![A-Za-z0-9])Person \\d+(?![0-9])"
  # Names are replaced with one regex per block of learned names, longest
  # first. One regex over thousands of names exceeds what PCRE compiles.
  @names_per_pattern 100
  # Longer text in a name position, such as a paragraph before `<address>`,
  # is no display name.
  @max_name_bytes 200
  @min_credential_bytes 8

  # `credentials` is a function returning `{variable, value}` pairs, so that
  # inspecting the state, as ExUnit does for failing calls, shows no values.
  defstruct fields: [],
            name_keys: @name_keys,
            keep_keys: ["fields"],
            credentials: nil,
            emails: %{},
            identifying: [],
            names: %{},
            compiled_names: nil,
            name_patterns: [],
            tokens: nil,
            reserved: MapSet.new(),
            values: %{}

  @doc """
  Builds a state from the `:fields`, `:name_keys`, `:keep_keys`,
  `:credentials` and `:identifying` options. `:credentials` and
  `:identifying` hold `{variable, value}` pairs whose values must not remain,
  such as tokens and configured email addresses.
  """
  def new(opts) do
    %__MODULE__{
      fields: strings(Keyword.get(opts, :fields, [])),
      name_keys: @name_keys ++ strings(Keyword.get(opts, :name_keys, [])),
      keep_keys: strings(Keyword.get(opts, :keep_keys, ["fields"])),
      credentials: credentials(Keyword.get(opts, :credentials, [])),
      identifying: Keyword.get(opts, :identifying, [])
    }
  end

  @doc "Sanitizes a decoded JSON value."
  def value(value, state) do
    state = value |> reserve(state) |> then(&collect(value, &1)) |> compile_names()
    replace(value, state)
  end

  @doc "Sanitizes free text such as a URL path or a header value."
  def text(text, state) when is_binary(text) do
    state = text |> reserve(state) |> then(&collect(text, &1)) |> compile_names()
    {replace_text(text, state), state}
  end

  @doc """
  Notes the placeholders that a value already holds, without replacing
  anything, so that values learned later get other numbers.

  Sanitizing sanitized output, such as the second fixture of a recording,
  keeps its placeholders. Reserve every part of a recording before the first
  one is sanitized.
  """
  def reserve(value, state) do
    value
    |> texts([])
    |> Enum.reduce(state, fn text, state ->
      found = @placeholder |> Regex.scan(text) |> List.flatten()
      found = if field_placeholder?(state, text), do: [text | found], else: found
      %{state | reserved: Enum.into(found, state.reserved)}
    end)
  end

  @doc """
  Drops auth, cookie, signature, forwarding and CloudFront edge headers and
  sanitizes the rest.
  """
  def headers(headers, state) do
    state = reserve(headers, state)

    headers
    |> Enum.reject(fn {name, _value} -> drop_header?(name) end)
    |> Enum.map_reduce(state, fn {name, value}, state ->
      {value, state} = header_value(value, state)
      {{String.downcase(to_string(name)), value}, state}
    end)
    |> then(fn {pairs, state} -> {Map.new(pairs), state} end)
  end

  @doc """
  Sanitizes a recorded fixture: its `body`, `headers` and `request.path`.

  The placeholders the fixture already holds are reserved first; the body
  goes next, so that the values found in it are known when the headers and
  the path are sanitized. The recorder and `LiveSmoke.sanitize_fixture/2`
  share this order.
  """
  def fixture(%{} = fixture, state) do
    state = reserve(fixture, state)
    {body, state} = value(fixture["body"], state)
    {headers, state} = headers(fixture["headers"] || %{}, state)
    {path, state} = text(get_in(fixture, ["request", "path"]) || "/", state)

    sanitized =
      fixture
      |> Map.merge(%{"body" => body, "headers" => headers})
      |> Map.update("request", %{"path" => path}, &Map.put(&1, "path", path))

    {sanitized, state}
  end

  @doc """
  Raises `LeakError` when the encoded value holds the value of a credential
  or of an identifying variable.
  """
  def check_leaks!(value, %__MODULE__{} = state) do
    encoded = Jason.encode!(value)
    form = String.replace(encoded, "+", " ")
    texts = Enum.uniq([encoded, percent_decode(encoded), percent_decode(form)])

    guarded =
      Enum.filter(state.identifying, fn {_variable, value} ->
        is_binary(value) and byte_size(value) >= @min_credential_bytes
      end)

    case Enum.find(state.credentials.() ++ guarded, fn {_variable, secret} ->
           leaked?(texts, secret)
         end) do
      nil -> :ok
      {variable, _secret} -> raise LeakError, variable: variable
    end
  end

  defp credentials(pairs) do
    pairs =
      Enum.filter(pairs, fn {_variable, value} ->
        is_binary(value) and byte_size(value) >= @min_credential_bytes
      end)

    fn -> pairs end
  end

  defp collect(map, state) when is_map(map) do
    Enum.reduce(map, state, fn {key, item}, state ->
      state = if is_binary(key), do: collect(key, state), else: state

      state =
        if is_binary(item) and to_string(key) in state.name_keys and
             not field_placeholder?(key, item),
           do: add_name(state, item),
           else: state

      collect(item, state)
    end)
  end

  defp collect(list, state) when is_list(list), do: Enum.reduce(list, state, &collect/2)

  defp collect(text, state) when is_binary(text) do
    state =
      if String.contains?(text, "<") and Regex.match?(@address_list, text) do
        @named_address
        |> Regex.scan(text, capture: :all_but_first)
        |> Enum.reduce(state, fn [quoted, bare, _address], state ->
          add_name(state, if(quoted == "", do: bare, else: quoted))
        end)
      else
        state
      end

    @email
    |> Regex.scan(text)
    |> List.flatten()
    |> Enum.reduce(state, &add_email(&2, &1))
  end

  defp collect(_other, state), do: state

  defp add_email(state, email) do
    key = String.downcase(email)

    if Map.has_key?(state.emails, key) or Regex.match?(@email_placeholder, key) do
      state
    else
      put_in(state.emails[key], free_placeholder(state, :emails, &"person-#{&1}@example.com"))
    end
  end

  defp add_name(state, name) do
    name = String.trim(name)

    if byte_size(name) < 3 or byte_size(name) > @max_name_bytes or String.contains?(name, "@") or
         Regex.match?(@name_placeholder, name) or Map.has_key?(state.names, name) do
      state
    else
      put_in(state.names[name], free_placeholder(state, :names, &"Person #{&1}"))
    end
  end

  # The placeholder with the lowest number that is neither given to another
  # value of the same kind nor reserved in the input.
  defp free_placeholder(state, kind, format) do
    given = state |> Map.fetch!(kind) |> Map.values() |> MapSet.new()

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(format)
    |> Enum.find(&(not MapSet.member?(given, &1) and not MapSet.member?(state.reserved, &1)))
  end

  # `fields:` writes `<key>-<n>` under a configured key.
  defp field_placeholder?(%__MODULE__{fields: fields}, item),
    do: Enum.any?(fields, &field_placeholder?(&1, item))

  defp field_placeholder?(key, item) do
    prefix = "#{key}-"
    String.starts_with?(item, prefix) and String.replace_prefix(item, prefix, "") =~ ~r/^\d+$/
  end

  defp replace(map, state) when is_map(map) do
    map
    |> Enum.map_reduce(state, fn {key, item}, state ->
      field = to_string(key)

      cond do
        Sanitizer.sensitive_key?(key) and field not in state.keep_keys ->
          {{key, "[redacted]"}, state}

        field in state.fields ->
          {item, state} = placeholder(item, field, state)
          {{key, item}, state}

        true ->
          {item, state} = replace(item, state)
          {{replace_key(key, state), item}, state}
      end
    end)
    |> then(fn {pairs, state} -> {Map.new(pairs), state} end)
  end

  defp replace(list, state) when is_list(list), do: Enum.map_reduce(list, state, &replace/2)
  defp replace(text, state) when is_binary(text), do: {replace_text(text, state), state}
  defp replace(other, state), do: {other, state}

  # Addresses become their placeholders. Names are replaced block by block,
  # each time only in the parts between addresses and placeholders, so a
  # placeholder written for one name is never matched by another.
  defp replace_text(text, state) do
    text =
      between_tokens(text, state.tokens, &Map.get(state.emails, String.downcase(&1), &1), & &1)

    Enum.reduce(state.name_patterns, text, fn {pattern, block}, text ->
      between_tokens(text, state.tokens, & &1, fn part ->
        Regex.replace(pattern, part, &name_placeholder(&1, block))
      end)
    end)
  end

  defp between_tokens(text, tokens, on_token, on_part) do
    tokens
    |> Regex.split(text, include_captures: true)
    |> Enum.with_index()
    |> Enum.map_join(fn
      {token, index} when rem(index, 2) == 1 -> on_token.(token)
      {part, _index} -> on_part.(part)
    end)
  end

  # Builds the token and name regexes after the names of a value are learned,
  # and again only when new names were learned. Names are never removed.
  defp compile_names(%__MODULE__{compiled_names: count, names: names} = state)
       when count == map_size(names),
       do: state

  defp compile_names(state) do
    fields =
      Enum.map(state.fields, &"|(?<![A-Za-z0-9_.~-])#{Regex.escape(&1)}-\\d+(?![0-9])")

    patterns =
      state.names
      |> Enum.sort_by(fn {name, _placeholder} -> -byte_size(name) end)
      |> Enum.chunk_every(@names_per_pattern)
      |> Enum.map(fn block ->
        names = Enum.map_join(block, "|", fn {name, _placeholder} -> Regex.escape(name) end)

        lookup =
          Map.new(block, fn {name, placeholder} -> {:string.casefold(name), placeholder} end)

        # Whole words only, so a name such as "Admin" leaves "Administrator" alone.
        {Regex.compile!("(?<![\\p{L}\\p{N}])(?:#{names})(?![\\p{L}\\p{N}])", "iu"),
         {lookup, block}}
      end)

    %{
      state
      | tokens: Regex.compile!(Enum.join([@token | fields])),
        name_patterns: patterns,
        compiled_names: map_size(state.names)
    }
  end

  # The regex matches names ignoring case. Case folding finds the name in
  # most cases; otherwise the block is searched for the name that matches.
  defp name_placeholder(match, {lookup, block}) do
    Map.get_lazy(lookup, :string.casefold(match), fn ->
      Enum.find_value(block, match, fn {name, placeholder} ->
        if Regex.match?(~r/\A#{Regex.escape(name)}\z/iu, match), do: placeholder
      end)
    end)
  end

  # Every string of a value: map keys and values.
  defp texts(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {key, item}, acc ->
      acc = if is_binary(key), do: [key | acc], else: acc
      texts(item, acc)
    end)
  end

  defp texts(list, acc) when is_list(list), do: Enum.reduce(list, acc, &texts/2)
  defp texts(text, acc) when is_binary(text), do: [text | acc]
  defp texts(_other, acc), do: acc

  defp replace_key(key, state) when is_binary(key), do: replace_text(key, state)
  defp replace_key(key, _state), do: key

  # A value that already is a placeholder of its field keeps it.
  defp placeholder(text, field, state) when is_binary(text) do
    cond do
      field_placeholder?(field, text) ->
        {text, state}

      Map.has_key?(state.values, {field, text}) ->
        {Map.fetch!(state.values, {field, text}), state}

      true ->
        placeholder = free_placeholder(state, :values, &"#{field}-#{&1}")
        {placeholder, put_in(state.values[{field, text}], placeholder)}
    end
  end

  defp placeholder(list, field, state) when is_list(list),
    do: Enum.map_reduce(list, state, &placeholder(&1, field, &2))

  defp placeholder(map, field, state) when is_map(map) do
    map
    |> Enum.map_reduce(state, fn {key, item}, state ->
      {item, state} = placeholder(item, field, state)
      {{replace_key(key, state), item}, state}
    end)
    |> then(fn {pairs, state} -> {Map.new(pairs), state} end)
  end

  defp placeholder(other, _field, state), do: {other, state}

  defp header_value(values, state) when is_list(values),
    do: Enum.map_reduce(values, state, &text/2)

  defp header_value(value, state) when is_binary(value), do: text(value, state)
  defp header_value(value, state), do: {value, state}

  defp drop_header?(name) do
    Sanitizer.sensitive_key?(name) or Regex.match?(@dropped_header, to_string(name))
  end

  # Besides the raw value, look for the JSON, form and Base64 encodings a
  # value takes in URLs, form bodies and encoded payloads. `texts` holds the
  # output and its percent-decoded forms, with `+` kept or read as a space, so
  # escapes in any case, and values only partly escaped, are found as well.
  defp leaked?(texts, secret) do
    candidates =
      Enum.uniq([
        secret,
        secret |> Jason.encode!() |> String.slice(1..-2//1),
        URI.encode_www_form(secret)
        | base64_cores(secret)
      ])

    Enum.any?(texts, fn text -> Enum.any?(candidates, &String.contains?(text, &1)) end)
  end

  # Decodes every `%XX` escape and leaves anything else as it is.
  defp percent_decode(text) do
    Regex.replace(~r/%([0-9A-Fa-f]{2})/, text, fn _escape, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end

  # A value inside longer Base64 content starts at byte 0, 1 or 2 of a
  # three-byte group, and each start gives other characters. Each core is the
  # part of the encoding that depends on the value alone: the characters that
  # mix in bytes before or after it are cut off.
  defp base64_cores(secret) do
    for shift <- 0..2,
        encode <- [&Base.encode64(&1, padding: false), &Base.url_encode64(&1, padding: false)] do
      encoded = encode.(:binary.copy(<<0>>, shift) <> secret)
      lead = Enum.at([0, 2, 3], shift)
      trail = if rem(shift + byte_size(secret), 3) == 0, do: 0, else: 1
      binary_part(encoded, lead, byte_size(encoded) - lead - trail)
    end
  end

  defp strings(values), do: Enum.map(values, &to_string/1)
end
