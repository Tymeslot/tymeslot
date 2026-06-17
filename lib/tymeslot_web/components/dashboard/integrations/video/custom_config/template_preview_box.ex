defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig.TemplatePreviewBox do
  @moduledoc """
  Preview box component for custom video URL template validation.

  Displays real-time feedback about template syntax with a stable, fixed-height layout
  that prevents any jumping or shifting when content changes.

  All states use an identical 3-row grid structure:
  - Row 1: Icon + Status label (fixed height)
  - Row 2: Message text (fixed height, may be empty)
  - Row 3: Preview code block (fixed height, may be hidden)
  """
  use Phoenix.Component

  @doc """
  Renders the template preview box.

  ## Attributes
    - status: :valid | :warning | :static | :empty
    - title: The status title/label (headline)
    - message: The description text (always present)
    - preview: Optional preview URL
  """
  attr :status, :atom, required: true
  attr :title, :string, required: true
  attr :message, :string, required: true, doc: "Description text"
  attr :preview, :string, default: nil, doc: "Optional preview URL"

  @spec render(any()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <div class={[
      "h-28 sm:h-32 transition-none",
      preview_container_class(@status)
    ]}>
      <div class="h-full flex gap-2.5 p-3 text-sm overflow-y-auto">
        <%!-- Icon Column (Fixed Width) --%>
        <div class="shrink-0 w-5">
          <.status_icon status={@status} />
        </div>

        <%!-- Content Column (Flex Layout) --%>
        <div class="flex-1 min-w-0 flex flex-col">
          <%!-- Row 1: Status Title (Always Present) --%>
          <div class={status_title_class(@status)}>
            {@title}
          </div>

          <%!-- Row 2: Description (Always Present) --%>
          <div class={message_class(@status)}>
            {@message}
          </div>

          <%!-- Row 3: Preview Code (With Top Margin) --%>
          <%= if @preview do %>
            <code class={preview_code_class(@status)}>
              {@preview}
            </code>
          <% else %>
            <div class="h-7 mt-2"></div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Icon rendering based on status
  defp status_icon(%{status: :valid} = assigns) do
    ~H"""
    <svg class="w-5 h-5 text-turquoise-600" fill="currentColor" viewBox="0 0 20 20">
      <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd" />
    </svg>
    """
  end

  defp status_icon(%{status: :warning} = assigns) do
    ~H"""
    <svg class="w-5 h-5 text-amber-600" fill="currentColor" viewBox="0 0 20 20">
      <path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd" />
    </svg>
    """
  end

  defp status_icon(%{status: :static} = assigns) do
    ~H"""
    <svg class="w-5 h-5 text-tymeslot-500" fill="currentColor" viewBox="0 0 20 20">
      <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd" />
    </svg>
    """
  end

  defp status_icon(%{status: :empty} = assigns) do
    ~H"""
    <svg class="w-5 h-5 text-tymeslot-400" fill="currentColor" viewBox="0 0 20 20">
      <path fill-rule="evenodd" d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z" clip-rule="evenodd" />
    </svg>
    """
  end

  # Container styling based on status
  defp preview_container_class(:valid),
    do: "rounded-lg border border-turquoise-200 bg-turquoise-50"

  defp preview_container_class(:warning), do: "rounded-lg border border-amber-200 bg-amber-50"

  defp preview_container_class(:static),
    do: "rounded-lg border border-tymeslot-200 bg-tymeslot-50"

  defp preview_container_class(:empty), do: "rounded-lg border border-tymeslot-200 bg-tymeslot-50"

  # Title styling based on status
  defp status_title_class(:valid), do: "font-semibold text-turquoise-800"
  defp status_title_class(:warning), do: "font-semibold text-amber-800"
  defp status_title_class(:static), do: "font-medium text-tymeslot-700"
  defp status_title_class(:empty), do: "text-tymeslot-500 italic"

  # Message styling based on status
  defp message_class(:valid), do: "text-xs text-turquoise-700 leading-relaxed"
  defp message_class(:warning), do: "text-xs text-amber-700 leading-relaxed"
  defp message_class(:static), do: "text-xs text-tymeslot-600 leading-relaxed"
  defp message_class(:empty), do: "text-xs text-tymeslot-500 leading-relaxed italic"

  # Preview code styling based on status
  defp preview_code_class(:valid),
    do:
      "text-xs text-tymeslot-700 bg-white px-2.5 py-1.5 rounded border border-turquoise-100 break-all font-mono block mt-2"

  defp preview_code_class(:warning),
    do:
      "text-xs text-tymeslot-700 bg-white px-2.5 py-1.5 rounded border border-amber-100 break-all font-mono block mt-2"

  defp preview_code_class(_code), do: ""
end
