defmodule Tymeslot.Integrations.Calendar.Shared.HttpLoggingTest do
  @moduledoc """
  The calendar transports' single redaction point, so it is covered here
  directly rather than only through whichever transport happens to call it: a
  regression in either helper leaks credentials or mailbox content from every
  caller at once.
  """

  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :security

  alias Tymeslot.Integrations.Calendar.Shared.HttpLogging

  # Distinctive enough that a match cannot be a coincidence, and nowhere near a
  # real credential.
  @leak_canary "corr3ct-horse-batt3ry-staple"

  describe "loggable_url/2" do
    test "keeps scheme and host and drops everything else by default" do
      assert HttpLogging.loggable_url("https://mail.example.com/EWS/Exchange.asmx?a=1") ==
               "https://mail.example.com"
    end

    test "keeps the path when the caller asks for it" do
      assert HttpLogging.loggable_url("https://dav.example.com/cal/user/home/",
               include_path: true
             ) == "https://dav.example.com/cal/user/home/"
    end

    test "drops userinfo whether or not the path is kept" do
      url = "https://svc:#{@leak_canary}@dav.example.com/cal/user/"

      assert HttpLogging.loggable_url(url) == "https://dav.example.com"

      assert HttpLogging.loggable_url(url, include_path: true) ==
               "https://dav.example.com/cal/user/"
    end

    test "renders a URL with no path as its origin even when the path is wanted" do
      assert HttpLogging.loggable_url("https://dav.example.com", include_path: true) ==
               "https://dav.example.com"
    end

    test "reports a URL it cannot reduce rather than echoing it" do
      # What a hostname typed into a configuration field parses as: `URI.parse/1`
      # reads the whole string as a path and leaves the scheme and host nil.
      assert HttpLogging.loggable_url("mail.example.com/EWS/Exchange.asmx") ==
               "(unparseable url)"

      assert HttpLogging.loggable_url("", include_path: true) == "(unparseable url)"
    end

    test "does not raise on a URL carrying a credential it cannot reduce" do
      assert HttpLogging.loggable_url("svc:#{@leak_canary}@mail.example.com") ==
               "(unparseable url)"
    end
  end

  describe "body_excerpt/1" do
    test "collapses whitespace so a multi-line error page reads as one line" do
      assert HttpLogging.body_excerpt("<error>\n  Unsupported\tmedia type\n</error>") ==
               "<error> Unsupported media type </error>"
    end

    test "keeps the head of a long body and drops the tail" do
      body = String.duplicate("a", 600) <> "TAIL"

      excerpt = HttpLogging.body_excerpt(body)

      assert String.starts_with?(excerpt, "aaaa")
      refute excerpt =~ "TAIL"
      assert String.length(excerpt) < String.length(body)
    end

    test "reports a body that is not text rather than rendering its bytes" do
      assert HttpLogging.body_excerpt(<<0xFF, 0xFE, 0x00>>) == "(non-text body)"
    end

    test "returns an empty excerpt for a body that is not a binary at all" do
      assert HttpLogging.body_excerpt(%{"parsed" => "already"}) == ""
      assert HttpLogging.body_excerpt(nil) == ""
    end
  end
end
