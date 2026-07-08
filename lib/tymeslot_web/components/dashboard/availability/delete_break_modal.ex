defmodule TymeslotWeb.Components.Dashboard.Availability.DeleteBreakModal do
  @moduledoc """
  Modal component for confirming break deletion.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents

  @max_break_label_length 80

  @doc """
  Renders a delete break confirmation modal.

  ## Attributes

    * `id` - The modal ID (required)
    * `show` - Boolean to show/hide the modal (required)
    * `break_data` - Map containing break id and info (required)
    * `on_cancel` - JS command to execute when canceling (required)
    * `on_confirm` - JS command to execute when confirming deletion (required)

  ## Examples

      <DeleteBreakModal.delete_break_modal
        id="delete-break-modal"
        show={@show_delete_break_modal}
        break_data={@delete_break_modal_data}
        on_cancel={JS.push("hide_delete_break_modal", target: @myself)}
        on_confirm={JS.push("confirm_delete_break", target: @myself)}
      />
  """
  attr :id, :string, required: true
  attr :show, :boolean, required: true
  attr :break_data, :map, required: true
  attr :on_cancel, JS, required: true
  attr :on_confirm, JS, required: true

  @spec delete_break_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_break_modal(assigns) do
    ~H"""
    <CoreComponents.modal id={@id} show={@show} on_cancel={@on_cancel} size={:medium}>
      <:header>
        <div class="flex items-center gap-2">
          <svg class="w-5 h-5 text-red-500" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L3.732 16.5c-.77.833.192 2.5 1.732 2.5z"
            />
          </svg>
          {dgettext("dashboard_availability", "Delete Break")}
        </div>
      </:header>

      <%= if @break_data do %>
        <div class="space-y-4">
          <p class="text-tymeslot-600 font-medium text-lg leading-relaxed">
            {dgettext("dashboard_availability", "Are you sure you want to delete this break%{label}?",
              label: format_break_label(@break_data)
            )}
          </p>
          <p class="text-tymeslot-500 font-medium">
            {dgettext("dashboard_availability", "This action cannot be undone.")}
          </p>
        </div>
      <% end %>

      <:footer>
        <div class="flex justify-end gap-3">
          <CoreComponents.action_button variant={:secondary} phx-click={@on_cancel}>
            {dgettext("dashboard_availability", "Cancel")}
          </CoreComponents.action_button>
          <CoreComponents.action_button variant={:danger} phx-click={@on_confirm}>
            {dgettext("dashboard_availability", "Delete Break")}
          </CoreComponents.action_button>
        </div>
      </:footer>
    </CoreComponents.modal>
    """
  end

  # Private helper functions

  defp format_break_label(break_data) when not is_map(break_data), do: ""

  defp format_break_label(break_data) do
    info = Map.get(break_data, :info) || Map.get(break_data, "info")

    label =
      case info do
        %{} -> Map.get(info, :label) || Map.get(info, "label")
        _other -> nil
      end

    label =
      if is_binary(label) do
        label
        |> String.trim()
        |> String.replace(~r/\s+/u, " ")
      else
        nil
      end

    label =
      cond do
        not is_binary(label) ->
          nil

        String.length(label) > @max_break_label_length ->
          String.slice(label, 0, @max_break_label_length - 3) <> "..."

        true ->
          label
      end

    if is_binary(label) and label != "" do
      " (#{label})"
    else
      ""
    end
  end
end
