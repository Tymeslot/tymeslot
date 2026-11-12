defmodule TymeslotWeb.Hooks.EditingLocaleHook do
  @moduledoc """
  Holds the dashboard's editing language: the translation language an
  organiser is writing their texts in, or nil for the original.

  It lives on the dashboard LiveView rather than in any one form, so that
  choosing Deutsch in the meeting type editor's language bar still has
  Deutsch chosen on the booking page text card. A form asks for a change by
  sending `{:editing_locale, code_or_nil}` to the LiveView
  (`TymeslotWeb.Dashboard.Languages.TranslatableForm` does); this hook takes
  that message before the LiveView's own `handle_info/2` and assigns
  `:editing_locale`, which the LiveView hands down to its sections.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  @spec on_mount(:default, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()}
  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> assign(:editing_locale, nil)
     |> attach_hook(:editing_locale, :handle_info, &handle_info/2)}
  end

  defp handle_info({:editing_locale, locale}, socket) when is_binary(locale) or is_nil(locale),
    do: {:halt, assign(socket, :editing_locale, locale)}

  defp handle_info(_message, socket), do: {:cont, socket}
end
