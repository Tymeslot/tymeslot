defmodule TymeslotWeb.Components.Dashboard.Appointments.OpenAttrs do
  @moduledoc """
  The bindings that make an agenda surface (a row, a card, a calendar block)
  open something on click, and how a keyboard reaches it.

  Every surface that opens an appointment builds its attributes here, so the
  overview, the calendar grid and the agenda list agree on what "clickable"
  means.
  """

  @typedoc """
  How a keyboard reaches the element:

    * `:own` (default): focusable as a button; Enter and Space click it through
      the dashboard's `data-keyboard-click` listener (`assets/js/keyboard_click.js`).
    * `:hook`: focusable as a button, inside a surface whose hook already turns
      Enter and Space on a `role="button"` into a click (the calendar grid's
      `CalendarDrag`); a second handler there would open it twice.
    * `:none`: the click only, for a real `<button>` or a surface with its own
      keyboard route.
  """
  @type keys :: :own | :hook | :none

  @doc """
  `phx-click` pushing `event`, with each of `values` as a `phx-value-*`.

  Options: `:keys` (see `t:keys/0`) and `:target`, the `phx-target`.
  """
  @spec build(String.t(), map(), keyword()) :: map()
  def build(event, values, opts \\ []) do
    values
    |> Map.new(fn {name, value} -> {"phx-value-#{name}", value} end)
    |> Map.put("phx-click", event)
    |> Map.merge(target_attrs(opts[:target]))
    |> Map.merge(key_attrs(Keyword.get(opts, :keys, :own)))
  end

  defp target_attrs(nil), do: %{}
  defp target_attrs(target), do: %{"phx-target" => target}

  defp key_attrs(:own),
    do: %{"data-keyboard-click" => true, "role" => "button", "tabindex" => "0"}

  defp key_attrs(:hook), do: %{"role" => "button", "tabindex" => "0"}
  defp key_attrs(:none), do: %{}
end
