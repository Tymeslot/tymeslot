defmodule Mix.Tasks.MirotalkProdSmoke do
  @moduledoc """
  Production-style smoke test for our MiroTalk integration.

  It creates a room using the same provider adapter flow we use in production,
  generates organizer + participant join URLs (with tokens), and then performs
  simple HTTP GET probes against both URLs to see if the server responds with
  an "invalid token" error.

  ## Usage

      mix mirotalk_prod_smoke

  Notes:
  - This task intentionally hardcodes config as top-level constants so it can be
    copied into production as-is for debugging.
  - Do NOT commit real production keys. Keep placeholders in git.
  """

  use Mix.Task

  require Logger

  alias Tymeslot.Integrations.Video.Providers.ProviderAdapter

  @shortdoc "Create MiroTalk room + probe organizer/participant join links"

  # ---------------------------------------------------------------------------
  # HARD-CODED CONFIG (edit in production for reproduction)
  # ---------------------------------------------------------------------------
  @mirotalk_base_url "<PUT_YOUR_MIROTALK_BASE_URL_HERE>" # e.g. "https://mirotalk.example.com"
  @mirotalk_api_key "<PUT_YOUR_MIROTALK_API_KEY_HERE>"

  # Use a future time so `exp` is definitely not expired.
  @meeting_time_offset_minutes 60

  @organizer_name "Smoke Organizer"
  @organizer_email "smoke.organizer@example.com"

  @participant_name "Smoke Participant"
  @participant_email "smoke.participant@example.com"

  # ---------------------------------------------------------------------------
  # HTTP probe settings
  # ---------------------------------------------------------------------------
  @probe_timeout_ms 20_000
  @probe_headers [
    {"user-agent", "tymeslot/mirotalk_prod_smoke"},
    {"accept", "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8"}
  ]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    base_url = get_base_url()
    api_key = get_api_key()

    ensure_config_set!(base_url, api_key)

    config = %{
      base_url: base_url,
      api_key: api_key
    }

    meeting_time =
      DateTime.add(DateTime.utc_now(), @meeting_time_offset_minutes * 60, :second)

    IO.puts("\n== MiroTalk production smoke test ==")
    IO.puts("base_url: #{base_url}")
    IO.puts("meeting_time (utc): #{DateTime.to_iso8601(meeting_time)}")

    {:ok, meeting_context} = ProviderAdapter.create_meeting_room(:mirotalk, config)

    room_id =
      meeting_context.room_data[:room_id] ||
        meeting_context.room_data["room_id"] ||
        "unknown"

    IO.puts("\nCreated room:")
    IO.puts("room_id: #{room_id}")

    {:ok, organizer_url} =
      ProviderAdapter.create_join_url(
        meeting_context,
        @organizer_name,
        @organizer_email,
        :organizer,
        meeting_time
      )

    {:ok, participant_url} =
      ProviderAdapter.create_join_url(
        meeting_context,
        @participant_name,
        @participant_email,
        :participant,
        meeting_time
      )

    IO.puts("\nGenerated join URLs:")
    IO.puts("organizer:  #{organizer_url}")
    IO.puts("participant: #{participant_url}")

    IO.puts("\nProbing join URLs (HTTP GET, follow redirects)...")
    organizer_result = probe_join_url(:organizer, organizer_url)
    participant_result = probe_join_url(:participant, participant_url)

    IO.puts("\n== Summary ==")
    print_probe_summary(organizer_result)
    print_probe_summary(participant_result)

    if organizer_result.invalid_token? or participant_result.invalid_token? do
      Mix.raise("Detected \"invalid token\" in at least one response body")
    end
  end

  defp ensure_config_set!(base_url, api_key) do
    if String.contains?(base_url, "<PUT_") or String.contains?(api_key, "<PUT_") do
      Mix.raise("""
      MiroTalk configuration not set. Please either:
        1. Set MIROTALK_BASE_URL and MIROTALK_API_KEY environment variables
        2. Edit `lib/mix/tasks/mirotalk_prod_smoke.ex` and set @mirotalk_base_url and @mirotalk_api_key
      """)
    end

    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        Mix.raise("Invalid MIROTALK_BASE_URL: #{base_url}")
    end
  end

  defp get_base_url do
    System.get_env("MIROTALK_BASE_URL") || @mirotalk_base_url
  end

  defp get_api_key do
    System.get_env("MIROTALK_API_KEY") || @mirotalk_api_key
  end

  defp probe_join_url(role, url) do
    uri = URI.parse(url)
    query_params = decode_query(uri.query)

    token = Map.get(query_params, "token")
    role_param = Map.get(query_params, "role")
    exp_param = Map.get(query_params, "exp")

    opts = [
      follow_redirect: true,
      timeout: @probe_timeout_ms,
      recv_timeout: @probe_timeout_ms
    ]

    result =
      case HTTPoison.get(url, @probe_headers, opts) do
        {:ok, %HTTPoison.Response{status_code: status, body: body, headers: headers}} ->
          invalid_token? = Regex.match?(~r/invalid token/i, body || "")

          %{
            role: role,
            url: url,
            status: status,
            invalid_token?: invalid_token?,
            body_bytes: byte_size(body || ""),
            content_type: header_value(headers, "content-type"),
            token_len: if(is_binary(token), do: String.length(token), else: 0),
            role_param: role_param,
            exp_param: exp_param,
            invalid_token_context: extract_match_context(body || "", ~r/invalid token/i, 80)
          }

        {:error, %HTTPoison.Error{reason: reason}} ->
          %{
            role: role,
            url: url,
            status: :http_error,
            invalid_token?: false,
            body_bytes: 0,
            content_type: nil,
            token_len: if(is_binary(token), do: String.length(token), else: 0),
            role_param: role_param,
            exp_param: exp_param,
            error: reason
          }
      end

    # High-signal per-link output right away.
    IO.puts("""
    - #{role}: status=#{inspect(result.status)} invalid_token?=#{result.invalid_token?} token_len=#{result.token_len} role_param=#{inspect(result.role_param)} exp=#{inspect(result.exp_param)} content_type=#{inspect(result.content_type)}
    """)

    if result.invalid_token? and is_binary(result.invalid_token_context) do
      IO.puts("  context: #{result.invalid_token_context}")
    end

    result
  end

  defp print_probe_summary(%{role: role} = result) do
    case result do
      %{status: :http_error, error: reason} ->
        IO.puts("- #{role}: HTTP error: #{inspect(reason)}")

      %{status: status} ->
        IO.puts(
          "- #{role}: status=#{status} invalid_token?=#{result.invalid_token?} content_type=#{inspect(result.content_type)} body_bytes=#{result.body_bytes}"
        )
    end
  end

  defp decode_query(nil), do: %{}
  defp decode_query(""), do: %{}

  defp decode_query(query) when is_binary(query) do
    URI.decode_query(query)
  rescue
    _ -> %{}
  end

  defp header_value(headers, name) when is_list(headers) and is_binary(name) do
    name_down = String.downcase(name)

    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name_down, do: v, else: nil

      _ ->
        nil
    end)
  end

  defp header_value(_, _), do: nil

  defp extract_match_context(body, regex, radius) do
    case Regex.run(regex, body, return: :index) do
      [{idx, len}] ->
        start_idx = max(idx - radius, 0)
        end_idx = min(idx + len + radius, String.length(body))
        String.replace(String.slice(body, start_idx, end_idx - start_idx), ~r/\s+/, " ")

      _ ->
        nil
    end
  end
end
