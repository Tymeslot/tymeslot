defmodule Mix.Tasks.Tymeslot.VerifyProxy do
  @moduledoc """
  Verifies HTTP proxy configuration and connectivity.

  This task helps diagnose proxy issues by:
  - Checking if proxy environment variables are set
  - Testing proxy connectivity
  - Verifying traffic flows through the proxy

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
  require Logger

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
    {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)

    # Start necessary applications
    Mix.Task.run("app.start")

    # Configure logging level
    if opts[:verbose] do
      Logger.configure(level: :debug)
    end

    # Display current environment
    print_environment()

    # Run verification
    if opts[:quick] do
      run_quick_check()
    else
      run_full_verification(opts)
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

  defp run_quick_check do
    Mix.shell().info("=== Running Quick Proxy Check ===\n")

    case Tymeslot.Infrastructure.ProxyVerifier.quick_check() do
      :ok ->
        Mix.shell().info(IO.ANSI.format([:green, "✓ SUCCESS: Proxy is working correctly\n"]))
        :ok

      {:error, reason} ->
        Mix.shell().error(IO.ANSI.format([:red, "✗ FAILED: #{reason}\n"]))
        Mix.raise("Proxy verification failed")
    end
  end

  defp run_full_verification(opts) do
    Mix.shell().info("=== Running Full Proxy Verification ===\n")

    verify_opts =
      []
      |> maybe_add_opt(:test_url, opts[:url])
      |> maybe_add_opt(:timeout, opts[:timeout])

    result = Tymeslot.Infrastructure.ProxyVerifier.verify(verify_opts)

    print_result(result)

    if result.traffic_flows_through_proxy do
      :ok
    else
      Mix.raise("Proxy verification failed")
    end
  end

  defp print_result(result) do
    Mix.shell().info("Results:")
    print_check("Proxy Configured", result.proxy_configured)
    print_check("Proxy Reachable", result.proxy_reachable)
    print_check("Traffic Flows Through Proxy", result.traffic_flows_through_proxy)

    if result.errors != [] do
      Mix.shell().info("\n" <> IO.ANSI.format([:red, :bright, "Errors:"]))

      Enum.each(result.errors, fn error ->
        Mix.shell().error("  - #{error}")
      end)
    end

    if map_size(result.details) > 0 do
      Mix.shell().info("\n" <> IO.ANSI.format([:bright, "Details:"]))
      print_details(result.details)
    end

    Mix.shell().info("")

    if result.traffic_flows_through_proxy do
      Mix.shell().info(IO.ANSI.format([:green, :bright, "✓ SUCCESS: Proxy verification passed\n"]))
    else
      Mix.shell().error(IO.ANSI.format([:red, :bright, "✗ FAILED: Proxy verification failed\n"]))
    end
  end

  defp print_check(label, true) do
    Mix.shell().info("  #{IO.ANSI.format([:green, "✓"])} #{label}")
  end

  defp print_check(label, false) do
    Mix.shell().info("  #{IO.ANSI.format([:red, "✗"])} #{label}")
  end

  defp print_details(details) do
    # Print config if present
    if config = details[:config] do
      Mix.shell().info("  Proxy Config:")

      if config.http_proxy do
        Mix.shell().info("    HTTP:  #{format_proxy(config.http_proxy)}")
      end

      if config.https_proxy do
        Mix.shell().info("    HTTPS: #{format_proxy(config.https_proxy)}")
      end

      if config.no_proxy != [] do
        Mix.shell().info("    NO_PROXY: #{Enum.join(config.no_proxy, ", ")}")
      end
    end

    # Print test details
    if proxy_used = details[:proxy_used] do
      Mix.shell().info("  Proxy Used: #{proxy_used}")
    end

    if test_url = details[:test_url] do
      Mix.shell().info("  Test URL: #{test_url}")
    end

    if status = details[:status] do
      Mix.shell().info("  Response Status: #{status}")
    end

    if origin_ip = details[:origin_ip] do
      Mix.shell().info("  Origin IP: #{origin_ip}")
    end
  end

  defp format_proxy(proxy) do
    auth = if proxy[:auth], do: "[#{proxy[:auth]}]", else: ""
    "#{proxy[:scheme]}://#{auth}#{proxy[:host]}:#{proxy[:port]}"
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
