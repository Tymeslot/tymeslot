defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.LivePreview do
  @moduledoc """
  Renders the live preview section for the embed settings dashboard.
  """
  use Phoenix.Component

  alias Tymeslot.Scheduling.LinkAccessPolicy

  @doc """
  Renders the live preview section.
  """
  attr :selected_embed_type, :string, required: true
  attr :username, :string, required: true
  attr :base_url, :string, required: true
  attr :embed_script_url, :string, required: true
  attr :embed_layout, :string, default: "column"
  attr :initial_height, :any, default: nil
  attr :max_width, :any, default: nil
  attr :is_ready, :boolean, required: true
  attr :error_reason, :any, required: true
  attr :myself, :any, required: true

  @spec live_preview(map()) :: Phoenix.LiveView.Rendered.t()
  def live_preview(assigns) do
    ~H"""
    <div class="bg-gradient-to-br from-tymeslot-50 to-tymeslot-100 rounded-token-2xl border-2 border-tymeslot-200 p-8">
      <div class="flex items-center mb-6">
        <div>
          <h3 class="text-token-2xl font-bold text-tymeslot-900">Test It Live</h3>
          <p class="text-tymeslot-600 mt-1">Try your booking widget in action</p>
        </div>
      </div>

      <div class="bg-white rounded-token-xl p-6 border-2 border-tymeslot-300 shadow-xl">
        <div class="text-center text-tymeslot-600 mb-4">
          <p class="font-semibold text-turquoise-700">Previewing: <%= String.capitalize(@selected_embed_type) %> Mode</p>
          <p class="text-token-sm">This is how your booking widget will appear on external sites</p>
        </div>

        <%!-- Readiness Warning --%>
        <div :if={!@is_ready} class="mb-6 p-4 bg-amber-50 border-2 border-amber-200 rounded-token-xl flex items-start space-x-3">
          <svg class="w-6 h-6 text-amber-600 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"></path>
          </svg>
          <div>
            <p class="text-token-sm font-bold text-amber-900">Link Deactivated</p>
            <p class="text-token-xs text-amber-800">
              <%= LinkAccessPolicy.reason_to_message(@error_reason) %>
            </p>
          </div>
        </div>

        <%!-- The actual booking widget will be loaded here via JavaScript --%>
        <div
          id="live-preview-container"
          phx-hook="EmbedPreview"
          data-username={@username}
          data-base-url={@base_url}
          data-embed-script-url={@embed_script_url}
          data-embed-type={@selected_embed_type}
          data-is-ready={to_string(@is_ready)}
          data-layout={@embed_layout}
          data-initial-height={@initial_height}
          data-max-width={@max_width}
          class="min-h-[400px] border-2 border-dashed border-tymeslot-200 rounded-token-lg flex items-center justify-center bg-tymeslot-50 overflow-hidden"
        >
        </div>
      </div>
    </div>
    """
  end
end
