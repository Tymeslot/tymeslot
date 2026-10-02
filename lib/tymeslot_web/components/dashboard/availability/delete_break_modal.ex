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
    <CoreComponents.confirm_modal
      id={@id}
      show={@show}
      title={dgettext("dashboard_availability", "Delete Break")}
      confirm_label={dgettext("dashboard_availability", "Delete Break")}
      on_cancel={@on_cancel}
      on_confirm={@on_confirm}
    >
      <%= if @break_data do %>
        <p>
          {dgettext("dashboard_availability", "Are you sure you want to delete this break%{label}?",
            label: format_break_label(@break_data)
          )}
        </p>
        <p class="text-tymeslot-500">
          {dgettext("dashboard_availability", "This action cannot be undone.")}
        </p>
      <% end %>
    </CoreComponents.confirm_modal>
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
