defmodule Tymeslot.Profiles.LegalLinksChangesetTest do
  use Tymeslot.DataCase, async: true

  @moduledoc """
  An organiser's legal notice and privacy policy links are stored tidy and
  held to http(s) URLs: https for a public host, http only for a local one.
  The input sanitiser leaves a URL's query string alone.
  """
  @moduletag :profiles
  @moduletag :schema

  import Tymeslot.Factory

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.InputValidation
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  defp change_links(attrs), do: ProfileSchema.legal_links_changeset(build(:profile), attrs)

  describe "legal_links_changeset/2" do
    test "accepts https URLs with a path, query and fragment" do
      url = "https://example.com/de/impressum?x=1&y=2#top"
      changeset = change_links(%{"legal_notice_url" => url})

      assert changeset.valid?
      assert get_change(changeset, :legal_notice_url) == url
    end

    test "a blank value clears the link" do
      profile = build(:profile, legal_notice_url: "https://example.com/old")

      changeset = ProfileSchema.legal_links_changeset(profile, %{"legal_notice_url" => "   "})

      assert changeset.valid?
      assert changeset.changes == %{legal_notice_url: nil}
    end

    test "strips null bytes before validating" do
      changeset = change_links(%{"privacy_policy_url" => "https://example.com/\x00p"})

      assert changeset.valid?
      assert get_change(changeset, :privacy_policy_url) == "https://example.com/p"
    end

    test "rejects other schemes" do
      for url <- ["javascript:alert(1)", "ftp://example.com", "mailto:a@b.c"] do
        changeset = change_links(%{"legal_notice_url" => url})
        refute changeset.valid?, "expected #{url} to be rejected"
        assert Keyword.has_key?(changeset.errors, :legal_notice_url)
      end
    end

    test "rejects http for a public host" do
      changeset = change_links(%{"privacy_policy_url" => "http://example.com/privacy"})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :privacy_policy_url)
    end

    test "allows http for a local host" do
      changeset = change_links(%{"privacy_policy_url" => "http://192.168.1.10/privacy"})

      assert changeset.valid?
    end

    test "rejects a URL over 2048 characters" do
      url = "https://example.com/" <> String.duplicate("a", 2048)
      changeset = change_links(%{"legal_notice_url" => url})

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :legal_notice_url)
    end

    test "leaves the other profile fields alone" do
      changeset =
        change_links(%{
          "full_name" => "Someone Else",
          "legal_notice_url" => "https://example.com/a",
          "privacy_policy_url" => "https://example.com/b"
        })

      assert changeset.valid?

      assert changeset.changes == %{
               legal_notice_url: "https://example.com/a",
               privacy_policy_url: "https://example.com/b"
             }
    end
  end

  describe "Profiles.update_legal_links/2" do
    test "persists and clears" do
      profile = insert(:profile)

      assert {:ok, _profile} =
               Profiles.update_legal_links(profile, %{
                 "legal_notice_url" => "https://example.com/impressum",
                 "privacy_policy_url" => "https://example.com/privacy"
               })

      saved = Repo.get!(ProfileSchema, profile.id)
      assert saved.legal_notice_url == "https://example.com/impressum"
      assert saved.privacy_policy_url == "https://example.com/privacy"

      assert {:ok, _profile} = Profiles.update_legal_links(saved, %{"legal_notice_url" => ""})

      reloaded = Repo.get!(ProfileSchema, profile.id)
      assert reloaded.legal_notice_url == nil
      assert reloaded.privacy_policy_url == "https://example.com/privacy"
    end

    test "returns the changeset for an invalid URL" do
      profile = insert(:profile)

      assert {:error, %Ecto.Changeset{}} =
               Profiles.update_legal_links(profile, %{"legal_notice_url" => "javascript:x"})
    end
  end

  describe "InputValidation.validate_legal_links/2" do
    test "leaves & ? # and % in a URL unescaped" do
      url = "https://example.com/p?x=1&y=2%20z#top"

      assert {:ok, out} = InputValidation.validate_legal_links(%{"legal_notice_url" => url})
      assert out["legal_notice_url"] == url
    end
  end
end
