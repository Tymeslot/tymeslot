defmodule Tymeslot.Emails.Shared.Styles.DarkModeTest do
  use ExUnit.Case, async: false

  @moduletag :emails

  alias Tymeslot.Emails.Shared.{Layouts, MjmlEmail, Styles}
  alias Tymeslot.Emails.Shared.Styles.{DarkMode, Tokens}
  alias Tymeslot.Utils.Colour

  # The `:confirmed` family follows the configured accent, so tests that move
  # it restore the original afterwards.
  setup do
    original = Application.get_env(:tymeslot, :email_brand_accent)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:tymeslot, :email_brand_accent)
        value -> Application.put_env(:tymeslot, :email_brand_accent, value)
      end
    end)

    :ok
  end

  describe "stylesheet/1" do
    test "puts every rule inside the dark colour-scheme media query" do
      css = DarkMode.stylesheet(%{text: [{"#111418", "#f2eee4"}]})

      [_before, inside] = String.split(css, "@media (prefers-color-scheme: dark) {", parts: 2)
      assert inside =~ "{color:#f2eee4 !important;}"
      refute css =~ ~r/\}\s*\[style/, "a rule escaped the media query"
    end

    test "anchors text selectors so a background of the same colour is left alone" do
      css = DarkMode.stylesheet(%{text: [{"#111418", "#f2eee4"}]})

      assert css =~ ~s([style^="color:#111418"])
      assert css =~ ~s([style*=";color:#111418"])
      assert css =~ ~s([style*="; color: #111418"])
      # An unanchored `color:#111418` would also match `background-color:#111418`.
      refute css =~ ~s([style*="color:#111418"])
    end

    test "matches backgrounds written as shorthand, longhand or bgcolor" do
      css = DarkMode.stylesheet(%{background: [{"#fafaf6", "#1b1e21"}]})

      for selector <- [
            ~s([bgcolor="#fafaf6"]),
            ~s([style*="background:#fafaf6"]),
            ~s([style*="background: #fafaf6"]),
            ~s([style*="background-color:#fafaf6"]),
            ~s([style*="background-color: #fafaf6"])
          ] do
        assert css =~ selector
      end

      assert css =~ "{background-color:#1b1e21 !important;}"
    end

    test "keeps a mapped text colour on its listed background with a more specific rule" do
      css =
        DarkMode.stylesheet(%{
          text: [{"#111418", "#f2eee4"}],
          keep_text: [{"#d97706", "#111418"}]
        })

      assert css =~ ~s([style*="#d97706"][style*="color:#111418"])
      assert css =~ "{color:#111418 !important;}"
    end
  end

  describe "the email palette" do
    test "every dark text colour reads against every dark surface text sits on" do
      assert low_contrast_pairs(Styles.dark_mode_styles()) == []
    end

    test "a pale or a dark custom accent still yields readable dark text" do
      for accent <- ["#f5d90a", "#1e1b4b"] do
        Application.put_env(:tymeslot, :email_brand_accent, accent)

        assert low_contrast_pairs(Styles.dark_mode_styles()) == [], accent
      end
    end

    test "an ink-text button keeps its dark ink on the accent" do
      deep = Tokens.intent_accent_deep(:alert)
      assert Styles.button_text_color(deep) == Tokens.ink()

      assert Styles.dark_mode_styles() =~ ~s([style*="#{deep}"][style*="color:#{Tokens.ink()}"])
    end
  end

  describe "rendered into an email" do
    test "the compiled HTML carries the dark stylesheet once, in the head" do
      html =
        "<mj-section><mj-column><mj-text>Body</mj-text></mj-column></mj-section>"
        |> Layouts.system_layout(intent: :confirmed, eyebrow: "Welcome")
        |> MjmlEmail.compile_mjml()

      [head, _body] = String.split(html, "</head>", parts: 2)

      assert length(String.split(html, "prefers-color-scheme: dark")) == 2
      assert head =~ "prefers-color-scheme: dark"
      assert head =~ ~s([bgcolor="#{Tokens.canvas()}"])
    end
  end

  # Every `{text, background}` pairing of the stylesheet's dark text colours
  # with its dark backgrounds that falls under WCAG AA. The hairline is a
  # 1px divider and carries no text, so it is left out, as is the light ink
  # the keep-text rules hold on accent buttons, which never meets a dark surface.
  defp low_contrast_pairs(css) do
    texts = css |> dark_values("color") |> List.delete(Tokens.ink())

    backgrounds =
      css |> dark_values("background-color") |> List.delete(Tokens.dark(:hairline))

    assert texts != [] and backgrounds != []

    for text <- texts,
        background <- backgrounds,
        Colour.contrast_ratio(text, background) < 4.5,
        do: {text, background}
  end

  defp dark_values(css, property) do
    ~r/\{#{property}:(#[0-9a-f]{6}) !important;\}/
    |> Regex.scan(css, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end
end
