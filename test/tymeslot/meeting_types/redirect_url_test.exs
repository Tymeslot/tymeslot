defmodule Tymeslot.MeetingTypes.RedirectUrlTest do
  @moduledoc """
  The redirect address rule, alone and through the meeting type changeset:
  blank is none, and anything else must be an absolute http(s) address the
  booking page can safely hand the browser.
  """

  use ExUnit.Case, async: true

  @moduletag :meeting_types

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.RedirectUrl

  describe "check/1" do
    test "blank is no address" do
      for blank <- [nil, "", "   "], do: assert(RedirectUrl.check(blank) == {:ok, nil})
    end

    test "an absolute http or https address is accepted, trimmed" do
      assert RedirectUrl.check(" https://example.com/thanks?a=1 ") ==
               {:ok, "https://example.com/thanks?a=1"}

      assert RedirectUrl.check("http://example.com") == {:ok, "http://example.com"}
      assert RedirectUrl.check("HTTPS://Example.com/") == {:ok, "HTTPS://Example.com/"}
    end

    test "anything a browser should not be sent to is refused" do
      for bad <- [
            "example.com/thanks",
            "/thank-you",
            "javascript:alert(1)",
            "data:text/html,hi",
            "ftp://example.com",
            "https:///path",
            "https://",
            "https://exa mple.com",
            123
          ] do
        assert {:error, {_message, _opts}} = RedirectUrl.check(bad), "accepted #{inspect(bad)}"
      end
    end

    test "an address over the limit is refused" do
      long = "https://example.com/" <> String.duplicate("a", RedirectUrl.max_length())

      assert {:error, {"should be at most %{count} character(s)", opts}} = RedirectUrl.check(long)
      assert opts[:count] == RedirectUrl.max_length()
    end
  end

  describe "the meeting type changeset" do
    defp changeset(attrs) do
      MeetingTypeSchema.changeset(
        %MeetingTypeSchema{},
        Map.merge(%{name: "Intro", duration_minutes: 30, user_id: 1}, attrs)
      )
    end

    test "stores a blank address as nil" do
      changeset = changeset(%{redirect_url: "  "})

      refute Keyword.has_key?(changeset.errors, :redirect_url)
      assert Changeset.get_field(changeset, :redirect_url) == nil
    end

    test "stores a valid address trimmed, with the switch" do
      changeset =
        changeset(%{redirect_url: " https://example.com/t ", redirect_pass_details: true})

      refute Keyword.has_key?(changeset.errors, :redirect_url)
      assert Changeset.get_change(changeset, :redirect_url) == "https://example.com/t"
      assert Changeset.get_change(changeset, :redirect_pass_details) == true
    end

    test "refuses an invalid address" do
      changeset = changeset(%{redirect_url: "example.com"})

      assert {"must be a full web address starting with http:// or https://", _opts} =
               changeset.errors[:redirect_url]
    end
  end
end
