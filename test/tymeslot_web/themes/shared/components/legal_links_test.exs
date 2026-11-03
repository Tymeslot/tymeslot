defmodule TymeslotWeb.Themes.Shared.Components.LegalLinksTest do
  @moduledoc """
  The footer every booking page carries: a link for each of the organiser's
  legal links that is set, the legal notice first, each opening in a new tab,
  and nothing at all when neither is set.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias TymeslotWeb.Themes.Shared.Components.LegalLinks

  @notice "https://example.com/imprint"
  @privacy "https://example.com/privacy"

  defp render(links) do
    assigns = %{links: links}
    rendered_to_string(~H"<LegalLinks.footer links={@links} />")
  end

  defp anchors(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("footer[data-testid='legal-links'] a")
  end

  test "renders both links in order with new-tab attributes" do
    links = anchors(render(%{legal_notice_url: @notice, privacy_policy_url: @privacy}))

    assert Enum.map(links, &(&1 |> Floki.attribute("href") |> hd())) == [@notice, @privacy]

    assert Enum.map(links, &(&1 |> Floki.text() |> String.trim())) == [
             "Legal notice",
             "Privacy policy"
           ]

    for link <- links do
      assert Floki.attribute(link, "target") == ["_blank"]
      assert Floki.attribute(link, "rel") == ["noopener noreferrer"]
    end
  end

  test "renders only the link that is set" do
    links = anchors(render(%{legal_notice_url: nil, privacy_policy_url: @privacy}))

    assert Enum.map(links, &Floki.attribute(&1, "href")) == [[@privacy]]
  end

  test "escapes a URL rather than writing it into the markup" do
    html =
      render(%{
        legal_notice_url: ~s(https://example.com/"><script>x</script>),
        privacy_policy_url: nil
      })

    refute html =~ "<script>"
  end

  test "renders nothing when both are nil" do
    refute render(%{legal_notice_url: nil, privacy_policy_url: nil}) =~
             ~s(data-testid="legal-links")
  end

  test "labels the links in German" do
    # The locale is per process, so this test's alone.
    Gettext.put_locale(TymeslotWeb.Gettext, "de")

    links = anchors(render(%{legal_notice_url: @notice, privacy_policy_url: @privacy}))

    assert Enum.map(links, &(&1 |> Floki.text() |> String.trim())) == ["Impressum", "Datenschutz"]
  end

  test "renders nothing for nil links" do
    refute render(nil) =~ ~s(data-testid="legal-links")
  end
end
