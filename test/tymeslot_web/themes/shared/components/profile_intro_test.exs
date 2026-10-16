defmodule TymeslotWeb.Themes.Shared.Components.ProfileIntroTest do
  use TymeslotWeb.ConnCase, async: true

  @moduledoc """
  The organiser's headline and bio as a theme renders them: escaped, the bio's
  blank lines as paragraphs and single line breaks as `<br>`, and nothing at
  all for an empty field, a missing profile or a profile map without the
  fields (a demo persona).
  """
  @moduletag :themes
  @moduletag :profiles
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Tymeslot.Profiles.ProfileSchema
  alias TymeslotWeb.Themes.Shared.Components.ProfileIntro

  defp bio(text), do: render_component(&ProfileIntro.bio/1, profile: %ProfileSchema{bio: text})

  defp headline(text),
    do: render_component(&ProfileIntro.headline/1, profile: %ProfileSchema{headline: text})

  # Each paragraph as its words and its number of <br> elements.
  defp paragraphs(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-testid='profile-bio'] p.profile-intro__paragraph")
    |> Enum.map(fn paragraph ->
      {paragraph |> LazyHTML.text() |> String.split(),
       paragraph |> LazyHTML.query("br") |> Enum.count()}
    end)
  end

  describe "bio/1" do
    test "renders each blank-line-separated block as a paragraph, single breaks as <br>" do
      html = bio("I help new managers.\nOne call at a time.\n\nBook a slot below.")

      assert paragraphs(html) == [
               {~w(I help new managers. One call at a time.), 1},
               {~w(Book a slot below.), 0}
             ]
    end

    test "treats CRLF like a newline and runs of blank lines as one break" do
      assert paragraphs(bio("First\r\n\r\n \r\n\r\nSecond\r\nline")) == [
               {~w(First), 0},
               {~w(Second line), 1}
             ]
    end

    test "escapes markup, so the text cannot add elements" do
      html = bio(~s|<script>alert(1)</script>\n<a href="https://example.com">link</a> & more|)

      refute html =~ "<script"
      refute html =~ "<a "
      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      assert html =~ "&amp; more"
    end

    test "renders nothing without a bio" do
      assert Enum.reject(
               [
                 bio(nil),
                 bio(""),
                 bio(" \n \n "),
                 render_component(&ProfileIntro.bio/1, profile: nil),
                 render_component(&ProfileIntro.bio/1, profile: %{full_name: "Demo persona"})
               ],
               &(String.trim(&1) == "")
             ) == []
    end
  end

  describe "headline/1" do
    test "renders the headline, escaped" do
      html = headline("<b>Coach</b> & mentor")

      assert html =~ ~s(data-testid="profile-headline")
      assert html =~ "&lt;b&gt;Coach&lt;/b&gt; &amp; mentor"
      refute html =~ "<b>"
    end

    test "renders nothing without a headline" do
      assert Enum.reject(
               [
                 headline(nil),
                 headline("   "),
                 render_component(&ProfileIntro.headline/1, profile: nil),
                 render_component(&ProfileIntro.headline/1, profile: %{full_name: "Demo persona"})
               ],
               &(String.trim(&1) == "")
             ) == []
    end
  end
end
