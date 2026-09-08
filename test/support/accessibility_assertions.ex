defmodule TymeslotWeb.AccessibilityAssertions do
  @moduledoc """
  Accessibility contracts asserted against a parsed Floki document.

  The public booking page and the dashboard timezone dropdown are separate
  implementations of the same control, and an audit found the same defects in
  both. The contracts live here so the two suites cannot drift into asserting
  different things about the same requirement. Callers stay responsible for
  reaching the state under test and for supplying the document; these functions
  only inspect markup.
  """

  import ExUnit.Assertions

  @doc """
  Approximates the accessible name of an element.

  Resolution order is `aria-labelledby`, then `aria-label`, then the element's
  own text, which is the order browsers apply. Ids are resolved against `doc`,
  which is why this takes the whole document rather than just the element.

  Everything past those three sources is deliberately out of scope: `title`
  attributes, `alt` text on nested images, and `aria-hidden` subtree pruning
  all change a real accessible name, but no control asserted on here derives
  its name from them, and hand-rolling the full algorithm would be a worse
  approximation than a small honest one.
  """
  @spec accessible_name(Floki.html_tree(), Floki.html_tree() | tuple()) :: String.t()
  def accessible_name(doc, element) do
    element = List.wrap(element)

    case Floki.attribute(element, "aria-labelledby") do
      [ids | _rest] ->
        labelledby_text(doc, ids)

      [] ->
        case Floki.attribute(element, "aria-label") do
          [label | _rest] -> collapse_whitespace(label)
          [] -> element |> Floki.text() |> collapse_whitespace()
        end
    end
  end

  @doc """
  Asserts that the control at `selector` is named by what a visitor can read.

  WCAG 2.5.3 Label in Name: an `aria-label` of "Select timezone" replaced the
  visible timezone, leaving speech-input users unable to activate the control
  by the words in front of them.

  `aria-label` is refused outright because it always replaces the visible text.
  `aria-labelledby` is not, since it can point back at that text: the name
  check below is what the criterion actually requires, and it keeps holding if
  the control is later renamed that way.
  """
  @spec assert_named_by_visible_text(Floki.html_tree(), String.t(), [String.t()]) :: :ok
  def assert_named_by_visible_text(doc, selector, fragments) do
    # Anchored: an empty fragment list would make the loop below assert nothing.
    assert fragments != [], "assert_named_by_visible_text/3 needs at least one fragment"

    assert [trigger] = Floki.find(doc, selector)

    assert Floki.attribute([trigger], "aria-label") == [],
           "#{selector} carries an aria-label, which replaces its visible text as the " <>
             "accessible name"

    name = accessible_name(doc, trigger)

    Enum.each(fragments, fn fragment ->
      assert name =~ fragment,
             "accessible name of #{selector} is #{inspect(name)}, " <>
               "expected it to contain #{inspect(fragment)}"
    end)

    :ok
  end

  @doc """
  Asserts that the trigger at `selector` announces the dialog it opens.

  `aria-haspopup="true"` means "menu", and a menu is a list of commands; the
  timezone panel is a dialog with a search box inside it.
  """
  @spec assert_announces_dialog(Floki.html_tree(), String.t()) :: :ok
  def assert_announces_dialog(doc, selector) do
    assert Floki.attribute(doc, selector, "aria-haspopup") == ["dialog"]

    :ok
  end

  @doc """
  Asserts that the single input at `selector` has a non-empty accessible name.

  A placeholder does not count: it disappears on first keystroke, and several
  screen readers never announce it at all.
  """
  @spec assert_input_named(Floki.html_tree(), String.t()) :: :ok
  def assert_input_named(doc, selector) do
    inputs = Floki.find(doc, selector)

    # Anchored: an empty list would satisfy the attribute check vacuously.
    assert length(inputs) == 1, "expected exactly one #{selector}, found #{length(inputs)}"

    assert [label] = Floki.attribute(inputs, "aria-label")
    assert label != "", "#{selector} has an empty aria-label"

    :ok
  end

  @doc """
  Asserts that every `<label>` in the document names a control.

  A label with neither a `for` nor a nested input is decoration that a screen
  reader announces as a stray phrase, and it leaves whatever field it sits
  above unnamed.

  Requires the document to contain at least one label. The check is otherwise
  satisfied by any page that renders none, which is how it can pass on a step
  that was never the one carrying the form. `context` is quoted verbatim in the
  failure message, so name the screen and the step.
  """
  @spec assert_no_orphan_labels(Floki.html_tree(), String.t()) :: :ok
  def assert_no_orphan_labels(doc, context) do
    labels = Floki.find(doc, "label")

    assert labels != [], "no labels rendered at #{context}, so this check proves nothing"

    orphans =
      Enum.reject(labels, fn label ->
        Floki.attribute([label], "for") != [] or
          Floki.find([label], "input, select, textarea") != []
      end)

    assert orphans == [],
           """
           Labels bound to nothing at #{context}:

           #{Enum.map_join(orphans, "\n", &"  - #{describe(&1)}")}
           """

    :ok
  end

  defp labelledby_text(doc, ids) do
    ids
    |> String.split(~r/\s+/, trim: true)
    |> Enum.map_join(" ", fn id -> doc |> Floki.find("##{id}") |> Floki.text() end)
    |> collapse_whitespace()
  end

  defp collapse_whitespace(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp describe({tag, attrs, _children}) do
    id = attrs |> List.keyfind("id", 0, {nil, nil}) |> elem(1)
    classes = attrs |> List.keyfind("class", 0, {nil, ""}) |> elem(1)

    text = classes |> String.split(~r/\s+/, trim: true) |> Enum.take(2) |> Enum.join(".")

    [tag, id && "##{id}", text != "" && ".#{text}"]
    |> Enum.filter(&is_binary/1)
    |> Enum.join()
  end
end
