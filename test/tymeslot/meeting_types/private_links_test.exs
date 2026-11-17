defmodule Tymeslot.MeetingTypes.PrivateLinksTest do
  @moduledoc """
  Tests for private booking links and custom slugs: slug resolution, the
  public/private visibility split, slug uniqueness and randomisation.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :meeting_types
  @moduletag :database

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo

  describe "effective_slug/1" do
    test "derives from the name when no custom slug is set" do
      type = insert(:meeting_type, name: "Coffee Chat", slug: nil)
      assert MeetingTypes.effective_slug(type) == "coffee-chat"
    end

    test "uses the custom slug when set" do
      type = insert(:meeting_type, name: "Coffee Chat", slug: "secret-9z")
      assert MeetingTypes.effective_slug(type) == "secret-9z"
    end
  end

  describe "find_by_slug/2" do
    test "resolves a type by its name-derived slug" do
      user = insert(:user)
      type = insert(:meeting_type, user: user, name: "Quick Chat", is_active: true)

      assert %{id: id} = MeetingTypes.find_by_slug(user.id, "quick-chat")
      assert id == type.id
    end

    test "resolves by the custom slug, not the stale name-derived one" do
      user = insert(:user)
      type = insert(:meeting_type, user: user, name: "Quick Chat", slug: "vip", is_active: true)

      assert %{id: id} = MeetingTypes.find_by_slug(user.id, "vip")
      assert id == type.id
      assert MeetingTypes.find_by_slug(user.id, "quick-chat") == nil
    end

    test "resolves a private but active type (privacy does not block the direct link)" do
      user = insert(:user)

      type =
        insert(:meeting_type,
          user: user,
          name: "Investor Call",
          is_private: true,
          is_active: true
        )

      assert %{id: id} = MeetingTypes.find_by_slug(user.id, "investor-call")
      assert id == type.id
    end

    test "does not resolve an inactive type (the link is paused when the type is off)" do
      user = insert(:user)
      insert(:meeting_type, user: user, name: "Paused", is_active: false)
      # keep the user from having zero types (which would auto-create defaults)
      insert(:meeting_type, user: user, name: "Other", is_active: true)

      assert MeetingTypes.find_by_slug(user.id, "paused") == nil
    end
  end

  describe "get_public_meeting_types/1" do
    test "excludes private types but keeps public ones" do
      user = insert(:user)

      public =
        insert(:meeting_type, user: user, name: "Public", is_active: true, is_private: false)

      private =
        insert(:meeting_type, user: user, name: "Hidden", is_active: true, is_private: true)

      ids = user.id |> MeetingTypes.get_public_meeting_types() |> Enum.map(& &1.id)

      assert public.id in ids
      refute private.id in ids
    end

    test "still excludes inactive types" do
      user = insert(:user)
      _inactive = insert(:meeting_type, user: user, name: "Off", is_active: false)
      active = insert(:meeting_type, user: user, name: "On", is_active: true)

      ids = user.id |> MeetingTypes.get_public_meeting_types() |> Enum.map(& &1.id)

      assert ids == [active.id]
    end

    test "returns nothing and seeds nothing for a host with no meeting types" do
      user = insert(:user)

      assert MeetingTypes.get_public_meeting_types(user.id) == []

      # A public page view must never write to the host's account: the default
      # "Intro call" type must not be conjured into existence.
      assert MeetingTypeQueries.list_all_meeting_types(user.id) == []
    end
  end

  describe "update_slug/2" do
    test "sets a custom slug" do
      type = insert(:meeting_type, name: "Quick Chat", slug: nil)

      assert {:ok, updated} = MeetingTypes.update_slug(type, "my-link")
      assert updated.slug == "my-link"
      assert MeetingTypes.effective_slug(updated) == "my-link"
    end

    test "blank slug reverts to the name-derived slug" do
      type = insert(:meeting_type, name: "Quick Chat", slug: "custom")

      assert {:ok, updated} = MeetingTypes.update_slug(type, "  ")
      assert updated.slug == nil
      assert MeetingTypes.effective_slug(updated) == "quick-chat"
    end

    test "rejects a slug that collides with another type's name-derived slug" do
      user = insert(:user)
      _a = insert(:meeting_type, user: user, name: "Coffee Chat", slug: nil)
      b = insert(:meeting_type, user: user, name: "Other", slug: nil)

      assert {:error, :slug_taken} = MeetingTypes.update_slug(b, "coffee-chat")
    end

    test "rejects an invalid slug format" do
      type = insert(:meeting_type, name: "Quick Chat")

      assert {:error, %Ecto.Changeset{}} = MeetingTypes.update_slug(type, "Bad Slug!")
    end

    test "lets a type keep its own effective slug" do
      type = insert(:meeting_type, name: "Quick Chat", slug: nil)

      assert {:ok, updated} = MeetingTypes.update_slug(type, "quick-chat")
      assert updated.slug == "quick-chat"
    end
  end

  describe "generate_random_slug/1" do
    test "produces a valid, lowercase, hyphen/alphanumeric slug" do
      user = insert(:user)
      slug = MeetingTypes.generate_random_slug(user.id)

      assert Regex.match?(~r/^[a-z0-9]+$/, slug)
    end

    test "does not collide with the user's existing effective slugs" do
      user = insert(:user)
      insert(:meeting_type, user: user, name: "Existing", is_active: true)

      slug = MeetingTypes.generate_random_slug(user.id)
      refute MeetingTypes.find_by_slug(user.id, slug)
    end
  end

  describe "set_private/2" do
    test "toggles the private flag without touching other fields" do
      type = insert(:meeting_type, name: "Chat", is_private: false, is_active: true)

      assert {:ok, updated} = MeetingTypes.set_private(type, true)
      assert updated.is_private == true
      assert updated.is_active == true

      assert {:ok, reverted} = MeetingTypes.set_private(updated, false)
      assert reverted.is_private == false
    end
  end

  describe "a name whose derived slug is reserved" do
    @reserved_link "would give a reserved booking link; choose another name or set a custom link"
    @reserved_names ["Thank you", "Poll", "30min"]

    defp type_attrs(user, extra),
      do: Map.merge(%{name: "Intro", duration_minutes: 30, user_id: user.id}, extra)

    test "is refused on the name when creating a type" do
      user = insert(:user)

      for name <- @reserved_names do
        assert {:error, cs} = MeetingTypes.create_meeting_type(type_attrs(user, %{name: name}))
        assert @reserved_link in errors_on(cs).name
      end

      assert MeetingTypes.get_all_meeting_types(user.id) == []
    end

    test "is refused on the name when renaming a type, leaving it unchanged" do
      type = insert(:meeting_type, name: "Intro", slug: nil)

      for name <- @reserved_names do
        assert {:error, cs} = MeetingTypes.update_meeting_type(type, %{name: name})
        assert @reserved_link in errors_on(cs).name
      end

      assert %{name: "Intro", slug: nil} = Repo.reload!(type)
    end

    test "is refused when submitted through the dashboard form" do
      user = insert(:user)
      params = %{"name" => "Thank you", "duration" => "30", "is_active" => "true"}

      assert {:error, %Changeset{} = cs} =
               MeetingTypes.create_meeting_type_from_form(user.id, params, %{
                 selected_icon: "hero-phone"
               })

      assert @reserved_link in errors_on(cs).name
    end

    test "is accepted with a custom slug" do
      user = insert(:user)

      for {name, slug} <- [
            {"Thank you", "thanks"},
            {"Poll", "quick-poll"},
            {"30min", "half-hour"}
          ] do
        assert {:ok, type} =
                 MeetingTypes.create_meeting_type(type_attrs(user, %{name: name, slug: slug}))

        assert MeetingTypes.effective_slug(type) == slug
      end
    end

    test "keeps its custom slug from being cleared" do
      type = insert(:meeting_type, name: "Thank you", slug: "thanks")

      assert {:error, cs} = MeetingTypes.update_slug(type, nil)
      assert @reserved_link in errors_on(cs).slug
      assert Repo.reload!(type).slug == "thanks"
    end

    test "on a type saved before the rule does not block its other settings" do
      type = insert(:meeting_type, name: "Thank you", slug: nil)

      assert {:ok, updated} = MeetingTypes.update_meeting_type(type, %{description: "Hi"})
      assert updated.description == "Hi"
    end
  end

  describe "slug_changeset/2 validation" do
    test "rejects the reserved <n>min duration shape" do
      type = insert(:meeting_type)
      cs = MeetingTypeSchema.slug_changeset(type, %{slug: "30min"})
      refute cs.valid?
    end

    test "rejects the reserved 'poll' slug that would shadow the voting page" do
      type = insert(:meeting_type)
      cs = MeetingTypeSchema.slug_changeset(type, %{slug: "poll"})
      refute cs.valid?
      assert "is reserved" in errors_on(cs).slug
    end

    test "rejects the reserved 'series' slug that would shadow the series page" do
      type = insert(:meeting_type)
      cs = MeetingTypeSchema.slug_changeset(type, %{slug: "series"})
      refute cs.valid?
      assert "is reserved" in errors_on(cs).slug
    end

    test "accepts lowercase alphanumerics and hyphens" do
      type = insert(:meeting_type)
      cs = MeetingTypeSchema.slug_changeset(type, %{slug: "vip-2026"})
      assert cs.valid?
    end

    test "downcases and trims, and treats blank as cleared (nil)" do
      type = insert(:meeting_type, slug: "old")
      cs = MeetingTypeSchema.slug_changeset(type, %{slug: "  VIP "})
      assert Changeset.get_field(cs, :slug) == "vip"

      cleared = MeetingTypeSchema.slug_changeset(type, %{slug: ""})
      assert Changeset.get_field(cleared, :slug) == nil
    end
  end
end
