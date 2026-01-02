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
  - `:allow_html` - Allow basic HTML tags (default: false)
  - `:log_events` - Log security events (default: true)
  - `:metadata` - Additional metadata for logging

  ## Examples

      iex> sanitize_and_validate("Hello world")
      {:ok, "Hello world"}
      
      iex> sanitize_and_validate("<script>alert('xss')</script>")
      {:ok, "alert('xss')"}
      
      iex> sanitize_and_validate("'; DROP TABLE users; --")
      {:ok, "' users "}
  """
  @spec sanitize_and_validate(any(), keyword()) :: {:ok, any()} | {:error, String.t()}
  def sanitize_and_validate(input, opts \\ [])

  def sanitize_and_validate(input, opts) when is_binary(input) do
    max_input_bytes = Keyword.get(opts, :max_input_bytes, 1_000_000)
    max_length = Keyword.get(opts, :max_length, 10_000)
    on_too_long = Keyword.get(opts, :on_too_long, :error)
    allow_html = Keyword.get(opts, :allow_html, false)
    log_events = Keyword.get(opts, :log_events, true)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_utf8(input, log_events, metadata),
         {:ok, bounded} <- enforce_max_input_bytes(input, max_input_bytes, on_too_long, log_events, metadata),
         {:ok, sanitized} <- sanitize_input(bounded, allow_html, log_events, metadata),
         {:ok, validated} <- validate_length(sanitized, max_length, on_too_long, log_events, metadata) do
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

  defp validate_utf8(input, log_events, metadata) do
    if String.valid?(input) do
      :ok
    else
      if log_events do
        SecurityLogger.log_blocked_input(:universal, "invalid_encoding", metadata)
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

        _ ->
          maybe_log_truncation(log_events, metadata, %{
            reason: "max_input_bytes",
            original_bytes: byte_size(input),
            max_input_bytes: max_input_bytes
          })

          {:error, "Input exceeds maximum size (#{max_input_bytes} bytes)"}
      end
    end
  end

  defp enforce_max_input_bytes(input, _max_input_bytes, _on_too_long, _log_events, _metadata),
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

  defp sanitize_input(input, allow_html, log_events, metadata) do
    original_input = input

    sanitized =
      input
      |> decode_url_recursive(3)
      |> sanitize_html(allow_html)
      |> remove_sql_injection_patterns(log_events, metadata)
      |> prevent_path_traversal(log_events, metadata)
      |> remove_dangerous_protocols(log_events, metadata)
      |> remove_null_bytes()

    # Log if malicious content was removed
    if log_events and sanitized != original_input do
      SecurityLogger.log_blocked_input(:universal, "sanitization", metadata)
    end

    {:ok, sanitized}
  end

  defp decode_url_recursive(input, 0), do: input

  defp decode_url_recursive(input, remaining) do
    case URI.decode(input) do
      ^input -> input
      decoded -> decode_url_recursive(decoded, remaining - 1)
    end
  rescue
    _ -> input
  end

  defp sanitize_html(input, true) do
    # Allow basic HTML for rich text fields
    HtmlSanitizeEx.basic_html(input)
  end

  defp sanitize_html(input, false) do
    # Strip all HTML tags for regular fields
    HtmlSanitizeEx.strip_tags(input)
  end

  defp remove_sql_injection_patterns(input, log_events, metadata) do
    original = input

    sanitized =
      input
      # Remove SQL comments
      |> String.replace(~r/--.*$/m, "")
      |> String.replace(~r/\/\*.*?\*\//m, "")
      # Remove obvious stacked queries
      |> String.replace(~r/;\s*(SELECT|INSERT|UPDATE|DELETE|DROP|CREATE|ALTER)\s/i, "; ")
      # Remove classic injection patterns
      |> String.replace(~r/'\s*(OR|AND)\s*'\d+'\s*=\s*'\d+/i, "'")
      |> String.replace(~r/"\s*(OR|AND)\s*"\d+"\s*=\s*"\d+/i, "\"")
      |> String.replace(~r/'\s*(OR|AND)\s*\d+\s*=\s*\d+/i, "'")
      # Remove UNION-based attacks
      |> String.replace(~r/\bUNION\s+(ALL\s+)?SELECT\s/i, "")
      # Remove dangerous SQL functions in injection context
      |> String.replace(~r/(0x[0-9a-fA-F]+|CHAR\s*\(\s*\d+)/i, "")

    if log_events and sanitized != original do
      SecurityLogger.log_blocked_input(:sql_injection, "pattern_removed", metadata)
    end

    sanitized
  end

  defp prevent_path_traversal(input, log_events, metadata) do
    original = input

    sanitized =
      input
      # Remove directory traversal patterns
      |> String.replace(~r/\.\.\/|\.\.\\/, "")
      # Remove dangerous absolute paths that could access system files
      |> remove_dangerous_absolute_paths()
      |> String.replace(~r/^[A-Za-z]:[\\\/]/, "")
      # Remove encoded traversal attempts
      |> String.replace(~r/%2e%2e|%252e%252e/i, "")
      |> String.replace(~r/%00|\\x00/, "")

    if log_events and sanitized != original do
      SecurityLogger.log_blocked_input(:path_traversal, "pattern_removed", metadata)
    end

    sanitized
  end

  # Remove dangerous absolute paths while preserving legitimate ones
  defp remove_dangerous_absolute_paths(input) do
    case input do
      # Preserve URLs completely
      "http" <> _ ->
        input

      # Check for dangerous system paths
      "/" <> _rest ->
        if dangerous_system_path?(input) do
          String.replace(input, ~r/^\/+/, "")
        else
          input
        end

      # Leave other inputs unchanged
      _ ->
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

  defp remove_dangerous_protocols(input, log_events, metadata) do
    original = input

    sanitized =
      input
      # Remove dangerous protocols with whitespace handling
      |> String.replace(~r/\b(javascript|data|vbscript)\s*:/i, "")
      |> String.replace(~r/(javascript|data|vbscript)\s*:/i, "")
      # Remove base64 data URIs
      |> String.replace(~r/base64[^,]*,/i, "")

    if log_events and sanitized != original do
      SecurityLogger.log_blocked_input(:dangerous_protocol, "protocol_removed", metadata)
    end

    sanitized
  end

  defp remove_null_bytes(input) do
    input
    |> String.replace(~r/\x00/, "")
    |> String.normalize(:nfc)
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

        _ ->
          {:error, "Input exceeds maximum length (#{max_length} characters)"}
      end
    end
  end
end
