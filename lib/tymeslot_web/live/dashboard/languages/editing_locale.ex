defmodule TymeslotWeb.Dashboard.Languages.EditingLocale do
  @moduledoc """
  Lets a dashboard section that reads its data in `update/2` skip that read
  when the only thing that changed is the dashboard's editing language
  (`TymeslotWeb.Hooks.EditingLocaleHook`).

  `DashboardLive` hands `:editing_locale` to whichever section is shown, so
  every click on a language bar re-renders the section with every other
  assign as it was. Nothing the section loads depends on the editing
  language: only its translatable forms do, and they take it from the
  re-render.
  """

  alias Phoenix.LiveView.Socket

  @doc """
  Whether `assigns`, handed to a section's `update/2`, change only its
  `:editing_locale`: the section has been updated before, the language
  differs, and every other assign is the one it already holds. A
  `send_update/3` that carries no `:editing_locale` is never one.
  """
  @spec only_change?(map(), Socket.t()) :: boolean()
  def only_change?(%{editing_locale: locale} = assigns, %Socket{assigns: current}) do
    case Map.fetch(current, :editing_locale) do
      {:ok, ^locale} ->
        false

      {:ok, _other} ->
        assigns
        |> Map.delete(:editing_locale)
        |> Enum.all?(fn {key, value} -> Map.fetch(current, key) == {:ok, value} end)

      :error ->
        false
    end
  end

  def only_change?(_assigns, _socket), do: false
end
