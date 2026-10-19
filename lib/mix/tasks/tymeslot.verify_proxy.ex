defmodule Mix.Tasks.Tymeslot.VerifyProxy do
  @moduledoc """
  Verifies HTTP proxy configuration and connectivity.

  This task helps diagnose proxy issues by:
  - Checking if proxy environment variables are set
  - Testing proxy connectivity
  - Verifying traffic flows through the proxy

  In a release, where Mix tasks cannot run, use
  `bin/tymeslot eval 'Tymeslot.Release.verify_proxy()'` instead; this task
  runs the same check.

  ## Usage

      # Basic verification with default test URL
      mix tymeslot.verify_proxy

      # Test with custom URL
      mix tymeslot.verify_proxy --url https://api.github.com

      # Quick check (faster, less comprehensive)
      mix tymeslot.verify_proxy --quick

  ## Environment Variables

  The task checks these standard proxy environment variables:
  - HTTP_PROXY / http_proxy
  - HTTPS_PROXY / https_proxy
  - NO_PROXY / no_proxy

  ## Examples

      # Test with corporate proxy
      $ export HTTPS_PROXY=http://proxy.corp.com:8080
      $ mix tymeslot.verify_proxy

      # Test with authenticated proxy
      $ export HTTPS_PROXY=http://user:pass@proxy.corp.com:8080
      $ mix tymeslot.verify_proxy

      # Test with NO_PROXY exclusions
      $ export HTTPS_PROXY=http://proxy.corp.com:8080
      $ export NO_PROXY=localhost,127.0.0.1,*.internal
      $ mix tymeslot.verify_proxy
  """

  use Mix.Task

  alias Tymeslot.Release

  @shortdoc "Verifies HTTP proxy configuration"

  @switches [
    url: :string,
    quick: :boolean,
    timeout: :integer,
    verbose: :boolean
  ]

  @aliases [
    u: :url,
    q: :quick,
    t: :timeout,
    v: :verbose
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _remaining_args} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    # Start necessary applications
    Mix.Task.run("app.start")

    # Configure logging level
    if opts[:verbose] do
      Logger.configure(level: :debug)
    end

    # Display current environment
    print_environment()

    # The release helper holds the check, so `bin/tymeslot eval` and this
    # task run the same one.
    release_opts =
      [quick: opts[:quick] == true]
      |> maybe_add_opt(:test_url, opts[:url])
      |> maybe_add_opt(:timeout, opts[:timeout])

    case Release.verify_proxy(release_opts) do
      :ok -> :ok
      {:error, _reason} -> Mix.raise("Proxy verification failed")
    end
  end

  defp print_environment do
    Mix.shell().info("\n=== Proxy Environment ===")

    env_vars = [
      {"HTTP_PROXY", System.get_env("HTTP_PROXY")},
      {"http_proxy", System.get_env("http_proxy")},
      {"HTTPS_PROXY", System.get_env("HTTPS_PROXY")},
      {"https_proxy", System.get_env("https_proxy")},
      {"NO_PROXY", System.get_env("NO_PROXY")},
      {"no_proxy", System.get_env("no_proxy")}
    ]

    Enum.each(env_vars, fn {name, value} ->
      display_value =
        if value do
          # Sanitize credentials in display
          sanitized = sanitize_proxy_url(value)
          IO.ANSI.format([:green, sanitized])
        else
          IO.ANSI.format([:faint, "(not set)"])
        end

      Mix.shell().info("  #{name}: #{display_value}")
    end)

    Mix.shell().info("")
  end

  defp sanitize_proxy_url(url) when is_binary(url) do
    uri = URI.parse(url)

    case uri.userinfo do
      nil ->
        url

      _userinfo ->
        # Replace credentials with [hidden]
        sanitized_uri = %{uri | userinfo: "[hidden]"}
        URI.to_string(sanitized_uri)
    end
  end

  defp sanitize_proxy_url(value), do: value

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
