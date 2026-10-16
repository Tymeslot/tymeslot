defmodule Tymeslot.Profiles.IntroChangesetTest do
  use Tymeslot.DataCase, async: true

  @moduledoc """
  The headline and bio are organiser-written text bound for a public page. The
  changeset stores them tidy (trimmed, blank as nil, no null bytes, a headline
  on one line, the bio's line breaks in one form) and holds them to their caps;
  the profiles context writes them through it and touches nothing else.
  """
  @moduletag :profiles
  @moduletag :schema

  import Tymeslot.Factory

  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  defp change_intro(attrs), do: ProfileSchema.intro_changeset(build(:profile), attrs)

  describe "intro_changeset/2" do
    test "keeps a headline and a bio" do
      changeset =
        change_intro(%{"headline" => "Career coach", "bio" => "I help new managers."})

      assert changeset.valid?
      assert get_change(changeset, :headline) == "Career coach"
      assert get_change(changeset, :bio) == "I help new managers."
    end

    test "trims both" do
      changeset = change_intro(%{"headline" => "  Career coach  ", "bio" => "\n I help. \n"})

      assert get_change(changeset, :headline) == "Career coach"
      assert get_change(changeset, :bio) == "I help."
    end

    test "stores a blank field as nil, clearing what was there" do
      profile = build(:profile, headline: "Old line", bio: "Old bio")

      changeset = ProfileSchema.intro_changeset(profile, %{"headline" => "   ", "bio" => ""})

      assert changeset.valid?
      assert fetch_change(changeset, :headline) == {:ok, nil}
      assert fetch_change(changeset, :bio) == {:ok, nil}
    end

    test "strips null bytes, which Postgres rejects" do
      changeset = change_intro(%{"headline" => "Coach\x00 and mentor", "bio" => "Line\x00 one"})

      assert get_change(changeset, :headline) == "Coach and mentor"
      assert get_change(changeset, :bio) == "Line one"
    end

    test "keeps the bio's line breaks, all as a newline" do
      changeset = change_intro(%{"bio" => "First line\r\nsecond line\r\rThird paragraph"})

      assert get_change(changeset, :bio) == "First line\nsecond line\n\nThird paragraph"
    end

    test "puts a headline on one line" do
      changeset = change_intro(%{"headline" => "Coach\r\nand\nmentor"})

      assert get_change(changeset, :headline) == "Coach and mentor"
    end

    test "accepts a headline of 120 characters and refuses 121" do
      assert change_intro(%{"headline" => String.duplicate("a", 120)}).valid?

      changeset = change_intro(%{"headline" => String.duplicate("a", 121)})
      assert errors_on(changeset)[:headline] == ["should be at most 120 character(s)"]
    end

    test "counts characters, not bytes, and only after trimming" do
      assert change_intro(%{"headline" => String.duplicate("é", 120)}).valid?
      assert change_intro(%{"headline" => "  " <> String.duplicate("a", 120) <> "  "}).valid?
    end

    test "accepts a bio of 1000 characters and refuses 1001" do
      assert change_intro(%{"bio" => String.duplicate("a", 1000)}).valid?

      changeset = change_intro(%{"bio" => String.duplicate("a", 1001)})
      assert errors_on(changeset)[:bio] == ["should be at most 1000 character(s)"]
    end

    test "casts nothing but the two fields" do
      changeset = change_intro(%{"headline" => "Coach", "full_name" => "Someone else"})

      assert Map.keys(changeset.changes) == [:headline]
    end
  end

  describe "Profiles.update_intro/2" do
    test "stores the headline and bio" do
      profile = insert(:profile)

      assert {:ok, _updated} =
               Profiles.update_intro(profile, %{
                 "headline" => " Career coach ",
                 "bio" => "One\r\ntwo"
               })

      stored = Repo.reload!(profile)
      assert {stored.headline, stored.bio} == {"Career coach", "One\ntwo"}
    end

    test "writes nothing when a field is over its cap" do
      profile = insert(:profile, headline: "Kept", bio: "Kept too")

      assert {:error, %Ecto.Changeset{}} =
               Profiles.update_intro(profile, %{
                 "headline" => String.duplicate("a", 121),
                 "bio" => "New"
               })

      stored = Repo.reload!(profile)
      assert {stored.headline, stored.bio} == {"Kept", "Kept too"}
    end

    test "leaves the rest of the profile alone" do
      profile = insert(:profile, full_name: "Sam Rivera")

      assert {:ok, _updated} =
               Profiles.update_intro(profile, %{"headline" => "Coach", "full_name" => "Changed"})

      assert Repo.reload!(profile).full_name == "Sam Rivera"
    end
  end
end
