defmodule Mix.Tasks.Css.CheckTokensTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  @script "scripts/test_css_tokens.sh"

  setup do
    root = Path.join(System.tmp_dir!(), "css-tokens-#{System.unique_integer([:positive])}")
    modules = Path.join(root, "themes/demo/modules")
    File.mkdir_p!(modules)
    File.mkdir_p!(Path.join(root, "shared/components"))

    # The real token contract, whose :where(:root) block defaults tokens the
    # shared styles read (the border widths, the role aliases and the rest).
    File.cp!("assets/css/scheduling/shared/tokens.css", Path.join(root, "shared/tokens.css"))

    File.write!(Path.join(root, "themes/demo/theme.css"), theme_css())

    File.write!(Path.join(modules, "variables.css"), variables_css())
    File.write!(Path.join(modules, "card.css"), ".card {\n  color: var(--ink-1);\n}\n")

    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, modules: modules}
  end

  test "passes when colour literals live only in token files", %{root: root} do
    File.write!(
      Path.join(root, "shared/tokens.css"),
      ":root {\n  --tint: rgba(0, 0, 0, 0.5);\n}\n"
    )

    assert {_output, 0} = run_script(root)
  end

  test "rejects an rgba() literal in a theme module", %{root: root, modules: modules} do
    File.write!(
      Path.join(modules, "card.css"),
      ".card {\n  background: rgba(255, 255, 255, 0.1);\n}\n"
    )

    assert {output, 1} = run_script(root)
    assert output =~ "themes/demo/modules/card.css:2:"
  end

  test "rejects a hex literal in a shared component", %{root: root} do
    File.write!(
      Path.join(root, "shared/components/notice.css"),
      ".notice {\n  color: #fbbf24;\n}\n"
    )

    assert {output, 1} = run_script(root)
    assert output =~ "shared/components/notice.css:2:"
  end

  test "rejects hardcoded spacing in a shared component", %{root: root} do
    File.write!(
      Path.join(root, "shared/components/notice.css"),
      ".notice {\n  padding: 12px;\n}\n"
    )

    assert {output, 1} = run_script(root)
    assert output =~ "shared/components/notice.css:2:"
  end

  test "rejects a hardcoded border width in a shared component", %{root: root} do
    File.write!(
      Path.join(root, "shared/components/notice.css"),
      ".notice {\n  border: 2px solid var(--line-1);\n}\n"
    )

    assert {output, 1} = run_script(root)
    assert output =~ "shared/components/notice.css:2:"
  end

  test "accepts tokenised spacing and borders in a shared component", %{root: root} do
    File.write!(
      Path.join(root, "shared/components/notice.css"),
      ".notice {\n  padding: var(--space-sm);\n  border: var(--border-width-thin) solid var(--line-1);\n}\n"
    )

    assert {_output, 0} = run_script(root)
  end

  test "rejects hardcoded spacing in a shared block", %{root: root} do
    File.mkdir_p!(Path.join(root, "shared/blocks"))
    File.write!(Path.join(root, "shared/blocks/chips.css"), ".chips {\n  gap: 12px;\n}\n")

    assert {output, 1} = run_script(root)
    assert output =~ "shared/blocks/chips.css:2:"
  end

  test "rejects a hardcoded border width in a shared block", %{root: root} do
    File.mkdir_p!(Path.join(root, "shared/blocks"))

    File.write!(
      Path.join(root, "shared/blocks/chips.css"),
      ".chips {\n  border: 2px solid var(--line-1);\n}\n"
    )

    assert {output, 1} = run_script(root)
    assert output =~ "shared/blocks/chips.css:2:"
  end

  test "ignores literals inside comments", %{root: root, modules: modules} do
    File.write!(
      Path.join(modules, "card.css"),
      ".card {\n  /* was rgba(0, 0, 0, 0.5) */\n  color: var(--ink-1);\n}\n"
    )

    assert {_output, 0} = run_script(root)
  end

  test "does not read an ID in a multi-line selector list as a hex colour",
       %{root: root, modules: modules} do
    File.write!(
      Path.join(modules, "card.css"),
      "#add-guest,\n#fade,\n.card #bad > .x {\n  color: var(--ink-1);\n}\n" <>
        "@media (min-width: 40rem) {\n  #cafe,\n  #beef {\n    color: var(--ink-2);\n  }\n}\n"
    )

    assert {_output, 0} = run_script(root)
  end

  test "rejects a hex literal in a declaration after a multi-line selector list",
       %{root: root, modules: modules} do
    File.write!(
      Path.join(modules, "card.css"),
      "#add-guest,\n#fade {\n  color: #fade;\n}\n"
    )

    assert {output, 1} = run_script(root)
    assert output =~ "themes/demo/modules/card.css:3:"
    refute output =~ "themes/demo/modules/card.css:1:"
  end

  test "rejects a token defined twice in a theme's variables.css",
       %{root: root, modules: modules} do
    File.write!(
      Path.join(modules, "variables.css"),
      variables_css() <> ":root {\n  --ink-1: 1;\n}\n"
    )

    assert {output, 1} = run_script(root)
    assert output =~ "Found duplicate token definitions"
    assert output =~ "--ink-1"
  end

  test "rejects a token read in shared/ that no theme is required to define", %{root: root} do
    File.write!(
      Path.join(root, "shared/components/notice.css"),
      ".notice {\n  color: var(--notice-undeclared-ink);\n}\n"
    )

    assert {output, 1} = run_script(root)
    assert output =~ "REQUIRED_TOKENS does not list"
    assert output =~ "--notice-undeclared-ink"
  end

  test "accepts a token read in shared/ that a shared file defines", %{root: root} do
    File.write!(
      Path.join(root, "shared/components/notice.css"),
      ":root {\n  --notice-local-gap: var(--space-sm);\n}\n.notice {\n  gap: var(--notice-local-gap);\n}\n"
    )

    assert {_output, 0} = run_script(root)
  end

  test "accepts a token read in shared/ that a shared :where(:root) block defaults", %{
    root: root
  } do
    File.write!(
      Path.join(root, "shared/tokens.css"),
      ":where(:root) {\n  --notice-default-gap: var(--space-sm);\n}\n"
    )

    File.write!(
      Path.join(root, "shared/components/notice.css"),
      ".notice {\n  gap: var(--notice-default-gap);\n}\n"
    )

    assert {_output, 0} = run_script(root)
  end

  test "accepts a token read in shared/ with a fallback", %{root: root} do
    File.write!(
      Path.join(root, "shared/components/notice.css"),
      ".notice {\n  border-color: var(--color-gray-200, currentColor);\n}\n"
    )

    assert {_output, 0} = run_script(root)
  end

  test "rejects a theme that leaves out a scale token the shared styles read",
       %{root: root, modules: modules} do
    File.write!(
      Path.join(modules, "variables.css"),
      String.replace(variables_css(), "  --icon-sm: 0;\n", "")
    )

    assert {output, 1} = run_script(root)
    assert output =~ "Missing token: --icon-sm"
  end

  describe "height media queries" do
    test "reject a block whose rules also apply to an embedded page",
         %{root: root, modules: modules} do
      File.write!(
        Path.join(modules, "card.css"),
        ".card {\n  color: var(--ink-1);\n}\n\n" <>
          "@media (max-height: 600px) {\n  .card {\n    aspect-ratio: auto;\n  }\n}\n"
      )

      assert {output, 1} = run_script(root)
      assert output =~ "themes/demo/modules/card.css:5: @media (max-height: 600px)"
    end

    test "accept a block whose rules are nested in the embed exclusion",
         %{root: root, modules: modules} do
      File.write!(
        Path.join(modules, "card.css"),
        "@media (max-height: 600px) and (min-width: 40rem) {\n" <>
          "  :where(html:not([data-embedded])) {\n    .card {\n      aspect-ratio: auto;\n    }\n  }\n}\n"
      )

      assert {output, 0} = run_script(root)
      assert output =~ "Every height media query leaves embedded pages alone"
    end

    test "reject a rule left beside the embed exclusion", %{root: root, modules: modules} do
      File.write!(
        Path.join(modules, "card.css"),
        "@media (orientation: landscape) {\n" <>
          "  :where(html:not([data-embedded])) {\n    .card {\n      aspect-ratio: auto;\n    }\n  }\n\n" <>
          "  .card__title {\n    display: none;\n  }\n}\n"
      )

      assert {output, 1} = run_script(root)
      assert output =~ "themes/demo/modules/card.css:1: @media (orientation: landscape)"
    end

    test "leave width queries alone", %{root: root, modules: modules} do
      File.write!(
        Path.join(modules, "card.css"),
        "@media (max-width: 640px) {\n  .card {\n    display: none;\n  }\n}\n"
      )

      assert {_output, 0} = run_script(root)
    end
  end

  test "rejects a theme without a variables.css", %{root: root, modules: modules} do
    File.rm!(Path.join(modules, "variables.css"))

    File.write!(
      Path.join(root, "themes/demo/theme.css"),
      String.replace(theme_css(), ~s(@import "./modules/variables.css";\n), "")
    )

    assert {output, 1} = run_script(root)
    assert output =~ "No modules/variables.css"
  end

  test "rejects a theme without a theme.css", %{root: root} do
    File.rm!(Path.join(root, "themes/demo/theme.css"))

    assert {output, 1} = run_script(root)
    assert output =~ "No theme.css"
  end

  test "rejects a theme that does not import a shared file every theme needs", %{root: root} do
    File.write!(
      Path.join(root, "themes/demo/theme.css"),
      theme_css("shared/components/polls.css")
    )

    assert {output, 1} = run_script(root)
    assert output =~ "Missing shared import: shared/components/polls.css"
  end

  test "accepts the shared import written with single quotes or a url()", %{root: root} do
    css =
      theme_css()
      |> String.replace(
        ~s(@import "../../shared/embed.css";),
        ~s(@import '../../shared/embed.css';)
      )
      |> String.replace(
        ~s(@import "../../shared/tokens.css";),
        ~s[@import url("../../shared/tokens.css");]
      )

    File.write!(Path.join(root, "themes/demo/theme.css"), css)
    assert {_output, 0} = run_script(root)
  end

  test "does not count a commented-out import", %{root: root} do
    css =
      String.replace(
        theme_css(),
        ~s(@import "../../shared/embed.css";),
        ~s(/* @import "../../shared/embed.css"; */)
      )

    File.write!(Path.join(root, "themes/demo/theme.css"), css)
    assert {output, 1} = run_script(root)
    assert output =~ "Missing shared import: shared/embed.css"
  end

  defp run_script(root) do
    System.cmd("bash", [@script], env: [{"SCHEDULING_CSS_ROOT", root}], stderr_to_stdout: true)
  end

  # Every token the script requires a theme to define, read from the script
  # itself so this fixture follows the list as it grows.
  defp variables_css do
    tokens =
      ~r/^\s+"(--[a-z0-9-]+)"\s*$/m
      |> Regex.scan(File.read!(@script), capture: :all_but_first)
      |> List.flatten()

    ":root {\n" <> Enum.map_join(tokens, "", &"  #{&1}: 0;\n") <> "}\n"
  end

  # Every shared file the script requires a theme to import, read from the
  # script itself, then the theme's own modules.
  defp theme_css(skip \\ nil) do
    shared =
      ~r/^\s+"(shared\/[a-z\/-]+\.css)"\s*$/m
      |> Regex.scan(File.read!(@script), capture: :all_but_first)
      |> List.flatten()
      |> List.delete(skip)

    Enum.map_join(shared, "", &~s(@import "../../#{&1}";\n)) <>
      ~s(@import "./modules/variables.css";\n@import "./modules/card.css";\n)
  end
end
