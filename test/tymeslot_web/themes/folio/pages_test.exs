defmodule TymeslotWeb.Themes.Folio.PagesTest do
  @moduledoc """
  Folio's page shell: the payment pages without a card, as the booking page
  they follow; the meeting and poll pages in Folio's card; and on every
  page the organiser's portrait and name below the band once the page holds
  their profile, the band alone before.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component
  import Phoenix.LiveViewTest
  import Tymeslot.Factory, only: [build: 2]

  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Folio.Pages

  @payment_pages [:payment_processing, :payment_cancelled]
  @card_pages [:cancel, :reschedule, :cancel_confirmed, :poll]

  defp shell(page, profile \\ nil) do
    assigns = %{page: page, profile: profile}

    ~H"""
    <Pages.page_shell page={@page} organizer_profile={@profile}>body</Pages.page_shell>
    """
    |> rendered_to_string()
    |> Floki.parse_fragment!()
  end

  test "draws the payment pages without a card" do
    for page <- @payment_pages do
      doc = shell(page)
      assert [_page] = Floki.find(doc, ".folio-plain-page")
      assert Floki.find(doc, ".folio-card") == []
    end
  end

  test "keeps the card for the meeting and poll pages" do
    for page <- @card_pages do
      doc = shell(page)
      assert [_card] = Floki.find(doc, ".folio-card")
      assert Floki.find(doc, ".folio-plain-page") == []
    end
  end

  test "draws the organiser's portrait and name below the band on the payment pages" do
    profile = build(:profile, full_name: "Mia Laurent")

    for page <- @payment_pages do
      doc = shell(page, profile)

      assert [portrait] = Floki.find(doc, ".folio-plain-page .folio-masthead img.folio-portrait")
      assert Floki.attribute(portrait, "src") == [Profiles.avatar_url(profile, :original)]

      assert doc |> Floki.find(".folio-masthead .folio-identity__name") |> Floki.text() ==
               "Mia Laurent"
    end
  end

  test "draws the organiser on the meeting and poll pages too" do
    profile = build(:profile, full_name: "Mia Laurent")

    for page <- @card_pages do
      doc = shell(page, profile)

      assert [_portrait] = Floki.find(doc, ".folio-card .folio-masthead img.folio-portrait")

      assert doc |> Floki.find(".folio-masthead .folio-identity__name") |> Floki.text() ==
               "Mia Laurent"
    end
  end

  test "draws the band alone without a profile" do
    for page <- @payment_pages ++ @card_pages do
      doc = shell(page)

      assert [_band] = Floki.find(doc, ".folio-masthead [data-testid='folio-cover']")
      assert Floki.find(doc, ".folio-identity") == []
    end
  end
end
