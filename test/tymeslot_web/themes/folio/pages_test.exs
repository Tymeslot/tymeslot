defmodule TymeslotWeb.Themes.Folio.PagesTest do
  @moduledoc """
  Folio's page shell: the payment pages without a card, as the booking page
  they follow; the meeting and poll pages in Folio's card.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Folio.Pages

  defp shell(page) do
    assigns = %{page: page}

    ~H"""
    <Pages.page_shell page={@page}>body</Pages.page_shell>
    """
    |> rendered_to_string()
    |> Floki.parse_fragment!()
  end

  test "draws the payment pages without a card" do
    for page <- [:payment_processing, :payment_cancelled] do
      doc = shell(page)
      assert [_page] = Floki.find(doc, ".folio-plain-page")
      assert Floki.find(doc, ".folio-card") == []
    end
  end

  test "keeps the card for the meeting and poll pages" do
    for page <- [:cancel, :reschedule, :cancel_confirmed, :poll] do
      doc = shell(page)
      assert [_card] = Floki.find(doc, ".folio-card")
      assert Floki.find(doc, ".folio-plain-page") == []
    end
  end
end
