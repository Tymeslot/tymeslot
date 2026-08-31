defmodule Tymeslot.Infrastructure.RedirectLocationTest do
  @moduledoc """
  The one place three subsystems ask "where does this redirect hop point?".

  Webhook delivery, the ICS feed fetcher and the custom video-provider probe
  all disable the HTTP client's own redirect step so each hop can be validated
  in its own right, then resolve the `Location` header through this module.
  Getting the answer wrong here is an SSRF hole in all three at once, so the
  awkward `Location` shapes are pinned individually rather than through the
  callers.
  """

  use ExUnit.Case, async: true

  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Infrastructure.RedirectLocation

  doctest RedirectLocation

  @base "https://feeds.example.com/a/calendar.ics"

  describe "next_url/2 - header shapes" do
    test "reads a Req-style map whose value is a list" do
      assert {:ok, "https://cdn.example.com/real.ics"} =
               RedirectLocation.next_url(
                 %{"location" => ["https://cdn.example.com/real.ics"]},
                 @base
               )
    end

    test "reads a map whose value is a bare binary" do
      assert {:ok, "https://cdn.example.com/real.ics"} =
               RedirectLocation.next_url(
                 %{"location" => "https://cdn.example.com/real.ics"},
                 @base
               )
    end

    test "reads a header list case-insensitively" do
      assert {:ok, "https://cdn.example.com/real.ics"} =
               RedirectLocation.next_url(
                 [
                   {"Content-Type", "text/html"},
                   {"Location", "https://cdn.example.com/real.ics"}
                 ],
                 @base
               )
    end

    test "reports a 3xx with no Location header" do
      assert {:error, :missing_location} = RedirectLocation.next_url(%{}, @base)
      assert {:error, :missing_location} = RedirectLocation.next_url([], @base)
    end

    test "reports headers that are neither a map nor a list" do
      assert {:error, :missing_location} = RedirectLocation.next_url(nil, @base)
    end
  end

  describe "next_url/2 - resolving against the current URL" do
    test "keeps an absolute target as it is" do
      assert {:ok, "https://other.example.com/hook"} =
               RedirectLocation.next_url(%{"location" => "https://other.example.com/hook"}, @base)
    end

    test "takes the scheme of the current URL for a protocol-relative target" do
      assert {:ok, "https://other.example.com/hook"} =
               RedirectLocation.next_url(%{"location" => "//other.example.com/hook"}, @base)

      assert {:ok, "http://other.example.com/hook"} =
               RedirectLocation.next_url(
                 %{"location" => "//other.example.com/hook"},
                 "http://feeds.example.com/a/calendar.ics"
               )
    end

    test "resolves an absolute path against the current host" do
      assert {:ok, "https://feeds.example.com/next.ics"} =
               RedirectLocation.next_url(%{"location" => "/next.ics"}, @base)
    end

    test "resolves a relative path against the current directory" do
      assert {:ok, "https://feeds.example.com/a/next.ics"} =
               RedirectLocation.next_url(%{"location" => "next.ics"}, @base)
    end

    test "keeps the query string of the target" do
      assert {:ok, "https://feeds.example.com/next.ics?token=abc"} =
               RedirectLocation.next_url(%{"location" => "/next.ics?token=abc"}, @base)
    end
  end

  describe "next_url/2 - targets that must not be followed" do
    test "refuses a scheme that is not HTTP" do
      for scheme <- ~w(ftp mailto file gopher data javascript) do
        assert {:error, :unsupported_target} =
                 RedirectLocation.next_url(
                   %{"location" => "#{scheme}://evil.example.com/x"},
                   @base
                 ),
               "#{scheme}: redirect must not be followable"
      end
    end

    test "refuses a mailto target, which parses without an authority" do
      assert {:error, :unsupported_target} =
               RedirectLocation.next_url(%{"location" => "mailto:ops@example.com"}, @base)
    end

    test "allows a plain http target, leaving the scheme policy to the caller" do
      # Webhook delivery rejects this afterwards via `SsrfValidator`; the video
      # probe deliberately accepts it. Baking an HTTPS rule in here would break
      # the second to protect the first.
      assert {:ok, "http://other.example.com/hook"} =
               RedirectLocation.next_url(%{"location" => "http://other.example.com/hook"}, @base)
    end
  end
end
