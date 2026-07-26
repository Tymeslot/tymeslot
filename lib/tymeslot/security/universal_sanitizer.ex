defmodule Tymeslot.Security.UniversalSanitizer do
  @moduledoc """
  Universal sanitization applied to all user inputs before field-specific validation.

  Provides protection against:
  - HTML/XSS attacks using HtmlSanitizeEx
  - SQL injection patterns
  - Path traversal attacks
  - Dangerous protocol injections
  """

  require Logger
  alias Tymeslot.Security.SecurityLogger

  @doc """
  Sanitizes input with universal security measures.

  ## Options
  - `:max_input_bytes` - Maximum allowed input size in bytes before sanitization (default: 1_000_000)
  - `:max_length` - Maximum allowed length (default: 10_000)
  - `:on_too_long` - Behavior when input exceeds `:max_length` (`:error` or `:truncate`, default: `:error`)
  - `:mode` - Sanitisation profile (`:strict` or `:plain_text`, default: `:strict`).
    Use `:plain_text` for free-form user-authored text (event titles, names,
    descriptions) that is only ever rendered through Phoenix templates (which
    auto-escape) and bound to Ecto queries as parameters. Plain-text mode
    skips HTML/SQL/path/protocol stripping so symbols like `<>`, `--`,
    `<email@x.com>` round-trip unchanged. It still validates UTF-8, strips
    null bytes, normalises to NFC, enforces length/byte limits, and trims
    whitespace. Do NOT use `:plain_text` for values that get interpolated
    into raw HTML strings, URLs, file paths, or shell commands.
  - `:allow_html` - Allow basic HTML tags (default: false). Ignored when `:mode` is `:plain_text`.
  - `:log_events` - Log security events (default: true)
  - `:metadata` - Additional metadata for logging

  ## Examples

      iex> sanitize_and_validate("Hello world")
      {:ok, "Hello world"}

      iex> sanitize_and_validate("<script>alert('xss')</script>")
      {:ok, "alert('xss')"}

      iex> sanitize_and_validate("'; DROP TABLE users; --")
      {:ok, "' users "}

      iex> sanitize_and_validate("Luka <> Paul", mode: :plain_text)
      {:ok, "Luka <> Paul"}
  """
  @spec sanitize_and_validate(any(), keyword()) :: {:ok, any()} | {:error, String.t()}
  def sanitize_and_validate(input, opts \\ [])

  def sanitize_and_validate(input, opts) when is_binary(input) do
    max_input_bytes = Keyword.get(opts, :max_input_bytes, 1_000_000)
    max_length = Keyword.get(opts, :max_length, 10_000)
    on_too_long = Keyword.get(opts, :on_too_long, :error)
    mode = Keyword.get(opts, :mode, :strict)
    allow_html = Keyword.get(opts, :allow_html, false)
    log_events = Keyword.get(opts, :log_events, true)
    metadata = Keyword.get(opts, :metadata, %{})
    field = Keyword.get(opts, :field, :unknown)

    with :ok <- validate_utf8(input, log_events, field, metadata),
         {:ok, bounded} <-
           enforce_max_input_bytes(input, max_input_bytes, on_too_long, log_events, metadata),
         {:ok, sanitized} <-
           sanitize_input(bounded, mode, allow_html, log_events, field, metadata),
         {:ok, validated} <-
           validate_length(sanitized, max_length, on_too_long, log_events, metadata) do
      {:ok, String.trim(validated)}
    end
  end

  def sanitize_and_validate(input, opts) when is_map(input) do
    result =
      Enum.reduce_while(input, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case sanitize_and_validate(value, opts) do
          {:ok, sanitized_value} -> {:cont, {:ok, Map.put(acc, key, sanitized_value)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    result
  end

  def sanitize_and_validate(input, opts) when is_list(input) do
    result =
      Enum.reduce_while(input, {:ok, []}, fn item, {:ok, acc} ->
        case sanitize_and_validate(item, opts) do
          {:ok, sanitized_item} -> {:cont, {:ok, [sanitized_item | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, sanitized_list} -> {:ok, Enum.reverse(sanitized_list)}
      error -> error
    end
  end

  def sanitize_and_validate(input, _opts), do: {:ok, input}

  # Private functions

  defp validate_utf8(input, log_events, field, metadata) do
    if String.valid?(input) do
      :ok
    else
      if log_events do
        SecurityLogger.log_blocked_input(field, "invalid_encoding", metadata)
      end

      {:error, "Invalid text encoding"}
    end
  end

  defp enforce_max_input_bytes(input, max_input_bytes, on_too_long, log_events, metadata)
       when is_integer(max_input_bytes) and max_input_bytes > 0 do
    if byte_size(input) <= max_input_bytes do
      {:ok, input}
    else
      case on_too_long do
        :truncate ->
          truncated = truncate_to_bytes(input, max_input_bytes)

          maybe_log_truncation(log_events, metadata, %{
            reason: "max_input_bytes",
            original_bytes: byte_size(input),
            max_input_bytes: max_input_bytes
          })

          {:ok, truncated}

        _other ->
          maybe_log_truncation(log_events, metadata, %{
            reason: "max_input_bytes",
            original_bytes: byte_size(input),
            max_input_bytes: max_input_bytes
          })

          {:error, "Input exceeds maximum size (#{max_input_bytes} bytes)"}
      end
    end
  end

  defp enforce_max_input_bytes(input, _max_bytes, _on_too_long, _log_events, _metadata),
    do: {:ok, input}

  defp truncate_to_bytes(input, max_bytes) when is_integer(max_bytes) and max_bytes >= 0 do
    input
    |> :binary.part(0, min(byte_size(input), max_bytes))
    |> trim_to_valid_utf8()
  end

  defp trim_to_valid_utf8(binary) do
    if String.valid?(binary) do
      binary
    else
      trim_to_valid_utf8(:binary.part(binary, 0, max(byte_size(binary) - 1, 0)))
    end
  end

  defp maybe_log_truncation(false, _metadata, _details), do: :ok

  defp maybe_log_truncation(true, metadata, details) do
    Logger.warning("Input truncated",
      event_type: "input_truncated",
      reason: details[:reason],
      original_length: details[:original_length],
      max_length: details[:max_length],
      original_bytes: details[:original_bytes],
      max_input_bytes: details[:max_input_bytes],
      ip_address: metadata[:ip],
      user_id: metadata[:user_id],
      user_agent: metadata[:user_agent]
    )

    SecurityLogger.log_security_event("input_truncated", %{
      ip_address: metadata[:ip],
      user_id: metadata[:user_id],
      user_agent: metadata[:user_agent],
      additional_data: details
    })
  end

  defp sanitize_input(input, :plain_text, _allow_html, _log_events, _field, _metadata) do
    # Plain-text mode: trust downstream layers (Phoenix auto-escaping, Ecto
    # parameterised queries) for XSS/SQLi protection. Only apply checks that
    # have value regardless of how the string is later consumed: encoding
    # integrity, null-byte stripping, and Unicode normalisation. Length and
    # whitespace handling happen in the caller pipeline.
    input
    |> remove_null_bytes()
    |> then(&{:ok, &1})
  end

  defp sanitize_input(input, _strict, allow_html, log_events, field, metadata) do
    input
    |> decode_url_recursive(3)
    |> remove_null_bytes()
    |> sanitize_html(allow_html)
    |> remove_sql_injection_patterns(log_events, field, metadata)
    |> prevent_path_traversal(log_events, field, metadata)
    |> remove_dangerous_protocols(log_events, field, metadata)
    |> then(&{:ok, &1})
  end

  defp decode_url_recursive(input, 0), do: input

  defp decode_url_recursive(input, remaining) do
    case URI.decode(input) do
      ^input -> input
      decoded -> decode_url_recursive(decoded, remaining - 1)
    end
  rescue
    exception ->
      # Debug rather than warning: the input is attacker-controlled, so a louder
      # level would let anyone flood the log with malformed percent-encoding.
      Logger.debug("Percent-decoding failed, sanitising the raw input instead",
        error: Exception.message(exception)
      )

      input
  end

  defp sanitize_html(input, true) do
    # Allow basic HTML for rich text fields
    HtmlSanitizeEx.basic_html(input)
  end

  defp sanitize_html(input, false) do
    # Plain-text fields: strip anything that looks like an HTML tag and leave
    # the rest alone. We deliberately don't use HtmlSanitizeEx.strip_tags/1
    # here — it entity-encodes `&`, `<`, `>`, `"`, `'` in its output, which
    # corrupts plain text round-tripping through Phoenix templates (which
    # already escape on render).
    String.replace(input, ~r/<[^>]*>/, "")
  end

  defp remove_sql_injection_patterns(input, log_events, field, metadata) do
    original = input

    sanitized =
      input
      # Remove SQL comments
      |> recursive_replace(~r/--.*$/m, "")
      |> recursive_replace(~r/\/\*.*?\*\//m, "")
      # Remove obvious stacked queries
      |> recursive_replace(~r/;\s*(SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER)\s/i, "; ")
      # Remove classic injection patterns
      |> recursive_replace(~r/'\s*(OR|AND)\s*'\d+'\s*=\s*'\d+/i, "'")
      |> recursive_replace(~r/"\s*(OR|AND)\s*"\d+"\s*=\s*"\d+/i, "\"")
      |> recursive_replace(~r/'\s*(OR|AND)\s*\d+\s*=\s*\d+/i, "'")
      # Remove UNION-based attacks
      |> recursive_replace(~r/\bUNION\s+(ALL\s+)?SELECT\s/i, "")
      # Remove dangerous SQL functions in injection context
      |> recursive_replace(~r/(0x[0-9a-fA-F]+|CHAR\s*\(\s*\d+)/i, "")

    if log_events and sanitized != original do
      SecurityLogger.log_blocked_input(field, "sql_injection", metadata)
    end

    sanitized
  end

  defp prevent_path_traversal(input, log_events, field, metadata) do
    original = input

    sanitized =
      input
      # Remove directory traversal patterns
      |> recursive_replace(~r/\.\.\/|\.\.\\/, "")
      # Remove dangerous absolute paths that could access system files
      |> remove_dangerous_absolute_paths()
      |> recursive_replace(~r/^[A-Za-z]:[\\\/]/, "")
      # Remove encoded traversal attempts
      |> recursive_replace(~r/%2e%2e|%252e%252e/i, "")
      |> recursive_replace(~r/%00|\\x00/, "")

    if log_events and sanitized != original do
      SecurityLogger.log_blocked_input(field, "path_traversal", metadata)
    end

    sanitized
  end

  # Remove dangerous absolute paths while preserving legitimate ones
  defp remove_dangerous_absolute_paths(input) do
    case input do
      # Preserve URLs completely
      "http" <> _url_rest ->
        input

      # Check for dangerous system paths
      "/" <> _path_rest ->
        if dangerous_system_path?(input) do
          String.replace(input, ~r/^\/+/, "")
        else
          input
        end

      # Leave other inputs unchanged
      _path ->
        input
    end
  end

  # Detect paths that could access sensitive system files
  defp dangerous_system_path?(path) do
    dangerous_patterns = [
      ~r/^\/etc\//,
      ~r/^\/bin\//,
      ~r/^\/sbin\//,
      ~r/^\/usr\/bin\//,
      ~r/^\/usr\/sbin\//,
      ~r/^\/root\//,
      # Hidden files in user directories
      ~r/^\/home\/[^\/]+\/\.\w/,
      ~r/^\/proc\//,
      ~r/^\/sys\//,
      ~r/^\/dev\//,
      # Suspicious files in tmp
      ~r/^\/tmp\/.*\.\w{2,4}$/,
      ~r/^\/var\/log\//,
      ~r/^\/boot\//
    ]

    Enum.any?(dangerous_patterns, &Regex.match?(&1, path))
  end

  defp remove_dangerous_protocols(input, log_events, field, metadata) do
    original = input

    sanitized =
      input
      # Remove dangerous protocols with whitespace handling
      |> recursive_replace(~r/\b(javascript|data|vbscript)\s*:/i, "")
      |> recursive_replace(~r/(javascript|data|vbscript)\s*:/i, "")
      # Remove base64 data URIs
      |> recursive_replace(~r/base64[^,]*,/i, "")

    if log_events and sanitized != original do
      SecurityLogger.log_blocked_input(field, "dangerous_protocol", metadata)
    end

    sanitized
  end

  defp remove_null_bytes(input) do
    input
    |> recursive_replace(~r/\x00/, "")
    |> String.normalize(:nfc)
  end

  defp recursive_replace(input, pattern, replacement, depth \\ 0) do
    # Limit recursion depth to prevent potential infinite loops
    if depth > 10 do
      input
    else
      case String.replace(input, pattern, replacement) do
        ^input -> input
        next -> recursive_replace(next, pattern, replacement, depth + 1)
      end
    end
  end

  defp validate_length(input, max_length, on_too_long, log_events, metadata) do
    if String.length(input) <= max_length do
      {:ok, input}
    else
      case on_too_long do
        :truncate ->
          maybe_log_truncation(log_events, metadata, %{
            reason: "max_length",
            original_length: String.length(input),
            max_length: max_length
          })

          {:ok, String.slice(input, 0, max_length)}

        _mode ->
          {:error, "Input exceeds maximum length (#{max_length} characters)"}
      end
    end
  end
end
