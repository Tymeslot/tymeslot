defmodule Tymeslot.BookingPages.BookingPageSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :unit

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.BookingPages.BookingPageSchema
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

  defp page_changeset(attrs) do
    BookingPageSchema.create_changeset(
      %BookingPageSchema{},
      Map.merge(%{profile_id: insert(:profile).id, booking_theme: "1"}, attrs)
    )
  end

  test "trims and lowercases the address" do
    changeset = page_changeset(%{name: " einfachISO ", slug: "  EinfachISO "})

    assert changeset.valid?
    assert Changeset.get_change(changeset, :slug) == "einfachiso"
    assert Changeset.get_change(changeset, :name) == "einfachISO"
  end

  test "refuses an address the username rules refuse" do
    refute page_changeset(%{name: "x", slug: "ab"}).valid?
    refute page_changeset(%{name: "x", slug: "has space"}).valid?
    refute page_changeset(%{name: "x", slug: "-leading"}).valid?
  end

  test "refuses a reserved address" do
    changeset = page_changeset(%{name: "Dash", slug: "dashboard"})

    assert {"is reserved", _opts} = changeset.errors[:slug]
  end

  test "refuses an unknown theme" do
    refute page_changeset(%{name: "x", slug: "fine-name", booking_theme: "99"}).valid?
  end

  test "the database refuses a second page with the same address in any case" do
    profile = insert(:profile)
    insert(:booking_page, profile: profile, slug: "einfachiso")

    {:error, changeset} =
      %BookingPageSchema{}
      |> BookingPageSchema.create_changeset(%{
        profile_id: profile.id,
        booking_theme: "1",
        name: "Again",
        slug: "EINFACHISO"
      })
      |> Repo.insert()

    assert {"has already been taken", _opts} = changeset.errors[:slug]
  end

  test "a profile row and a page row may share a theme" do
    profile = insert(:profile)
    page = insert(:booking_page, profile: profile)

    insert(:theme_customization, profile: profile, theme_id: "1")
    insert(:theme_customization, profile: profile, booking_page: page, theme_id: "1")

    assert Repo.aggregate(ThemeCustomizationSchema, :count) == 2
  end
end
