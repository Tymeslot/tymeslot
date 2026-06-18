defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.OptionsGrid do
  @moduledoc """
  Renders the embed options grid for the dashboard.
  """
  use TymeslotWeb, :html

  alias TymeslotWeb.Live.Dashboard.EmbedSettings.Helpers

  @doc """
  Renders the embed options grid.
  """
  attr :selected_embed_type, :string, required: true
  attr :username, :string, required: true
  attr :base_url, :string, required: true
  attr :booking_url, :string, required: true
  attr :embed_layout, :string, default: "column"
  attr :initial_height, :any, default: nil
  attr :max_width, :any, default: nil
  attr :myself, :any, required: true

  @spec options_grid(map()) :: Phoenix.LiveView.Rendered.t()
  def options_grid(assigns) do
    assigns = assign(assigns, :snippet_options, Helpers.snippet_options(assigns))

    ~H"""
    <.customise_panel
      embed_layout={@embed_layout}
      initial_height={@initial_height}
      max_width={@max_width}
      myself={@myself}
    />

    <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
      <.embed_option_card
        type="inline"
        selected={@selected_embed_type == "inline"}
        title="Inline Embed"
        description="Embed directly into your webpage"
        badge="Recommended"
        badge_class="bg-turquoise-100 text-turquoise-700"
        myself={@myself}
      >
        <:preview>
          <div class="bg-white rounded shadow-sm p-4">
            <div class="flex items-center space-x-2 mb-3">
              <div class="w-3 h-3 rounded-full bg-red-400"></div>
              <div class="w-3 h-3 rounded-full bg-yellow-400"></div>
              <div class="w-3 h-3 rounded-full bg-green-400"></div>
            </div>
            <div class="space-y-2">
              <div class="h-2 bg-tymeslot-200 rounded w-3/4"></div>
              <div class="h-2 bg-tymeslot-200 rounded w-1/2"></div>
              <div class="mt-4 p-3 bg-linear-to-br from-turquoise-50 to-cyan-50 border-2 border-turquoise-200 rounded-token-lg">
                <div class="flex items-center space-x-2">
                  <svg class="w-4 h-4 text-turquoise-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"></path>
                  </svg>
                  <div class="text-token-xs font-semibold text-turquoise-700">Your booking widget here</div>
                </div>
              </div>
              <div class="h-2 bg-tymeslot-200 rounded w-2/3"></div>
            </div>
          </div>
        </:preview>
        <:code>
          {Helpers.embed_code("inline", @snippet_options)}
        </:code>
        <:footer_info>
          Shows the booking calendar right on your page. Copy the code and paste it into your website's HTML.
        </:footer_info>
      </.embed_option_card>

      <%!-- Popup Modal option card --%>
      <.embed_option_card
        type="popup"
        selected={@selected_embed_type == "popup"}
        title="Popup Modal"
        description="Trigger a modal overlay with a button"
        badge="Popular"
        badge_class="bg-blue-100 text-blue-700"
        myself={@myself}
      >
        <:preview>
          <div class="bg-white rounded shadow-sm p-4">
            <div class="flex items-center space-x-2 mb-3">
              <div class="w-3 h-3 rounded-full bg-red-400"></div>
              <div class="w-3 h-3 rounded-full bg-yellow-400"></div>
              <div class="w-3 h-3 rounded-full bg-green-400"></div>
            </div>
            <div class="space-y-2">
              <div class="h-2 bg-tymeslot-200 rounded w-3/4"></div>
              <div class="h-2 bg-tymeslot-200 rounded w-1/2"></div>
              <div class="mt-4 flex justify-center">
                <div class="px-4 py-2 text-white text-token-xs font-bold rounded-token-lg shadow-lg bg-turquoise-600">
                  Book a Meeting →
                </div>
              </div>
              <div class="h-2 bg-tymeslot-200 rounded w-2/3"></div>
            </div>
          </div>
        </:preview>
        <:code>
          {Helpers.embed_code("popup", @snippet_options)}
        </:code>
        <:footer_info>
          Visitors click a button on your page and the booking calendar opens in an overlay.
        </:footer_info>
      </.embed_option_card>

      <.embed_option_card
        type="link"
        selected={@selected_embed_type == "link"}
        title="Direct Link"
        description="Simple link to your booking page"
        badge="Easiest"
        badge_class="bg-tymeslot-100 text-tymeslot-700"
        myself={@myself}
      >
        <:preview>
          <div class="bg-white rounded shadow-sm p-4">
            <div class="flex items-center space-x-2 mb-3">
              <div class="w-3 h-3 rounded-full bg-red-400"></div>
              <div class="w-3 h-3 rounded-full bg-yellow-400"></div>
              <div class="w-3 h-3 rounded-full bg-green-400"></div>
            </div>
            <div class="space-y-2">
              <div class="h-2 bg-tymeslot-200 rounded w-3/4"></div>
              <div class="h-2 bg-tymeslot-200 rounded w-1/2"></div>
              <div class="mt-4">
                <div class="text-token-xs text-turquoise-600 underline font-medium">
                  Schedule a meeting with me →
                </div>
              </div>
              <div class="h-2 bg-tymeslot-200 rounded w-2/3"></div>
            </div>
          </div>
        </:preview>
        <:code>
          {Helpers.embed_code("link", @snippet_options)}
        </:code>
        <:footer_info>
          Share this link in emails, social media bios, or messages. No code needed.
        </:footer_info>
      </.embed_option_card>

      <.embed_option_card
        type="floating"
        selected={@selected_embed_type == "floating"}
        title="Floating Button"
        description="Fixed button in corner of page"
        badge="Pro"
        badge_class="bg-purple-100 text-purple-700"
        myself={@myself}
      >
        <:preview>
          <div class="mb-0 bg-tymeslot-50 rounded-token-lg p-0 relative overflow-hidden">
            <div class="bg-white rounded shadow-sm p-4">
              <div class="flex items-center space-x-2 mb-3">
                <div class="w-3 h-3 rounded-full bg-red-400"></div>
                <div class="w-3 h-3 rounded-full bg-yellow-400"></div>
                <div class="w-3 h-3 rounded-full bg-green-400"></div>
              </div>
              <div class="space-y-2">
                <div class="h-2 bg-tymeslot-200 rounded w-3/4"></div>
                <div class="h-2 bg-tymeslot-200 rounded w-1/2"></div>
                <div class="h-2 bg-tymeslot-200 rounded w-2/3"></div>
              </div>
            </div>
            <%!-- Floating button preview --%>
            <div class="absolute bottom-4 right-4">
              <div class="w-8 h-8 rounded-full shadow-lg flex items-center justify-center bg-turquoise-600">
                <svg class="w-4 h-4 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"></path>
                </svg>
              </div>
            </div>
          </div>
        </:preview>
        <:code>
          {Helpers.embed_code("floating", @snippet_options)}
        </:code>
        <:footer_info>
          A floating button stays visible as visitors scroll — like a chat widget, but for booking.
        </:footer_info>
      </.embed_option_card>
    </div>

    <%!-- Hardcoded link to the cloud docs hub (slash-docs is not available in standalone Core) --%>
    <p class="mt-6 text-center text-token-sm text-tymeslot-500">
      Need help? See the
      <a
        href="https://tymeslot.app/docs/embed"
        target="_blank"
        rel="noopener noreferrer"
        class="text-turquoise-600 hover:text-turquoise-700 font-medium underline"
      >
        embedding guide
      </a>
      for step-by-step instructions, platform tips, and customization options.
    </p>
    """
  end

  # Customisation panel — controls that drive every card's generated snippet.
  # Three knobs:
  #   - layout: "column" (default — wide canvas, adapts to any container) or
  #     "default" (centred-with-cap, for standalone-style placements)
  #   - initial-height: placeholder height (px) shown before the iframe auto-resizes
  #   - max-width: container max-width (px) for inline + popup + floating
  attr :embed_layout, :string, required: true
  attr :initial_height, :any, required: true
  attr :max_width, :any, required: true
  attr :myself, :any, required: true

  defp customise_panel(assigns) do
    ~H"""
    <div class="mb-6 bg-white border-2 border-tymeslot-200 rounded-token-lg p-6">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h3 class="text-token-lg font-bold text-tymeslot-900">Customise</h3>
          <p class="text-token-sm text-tymeslot-600 mt-1">
            Updates every snippet below. Defaults work for most embeds — adjust when your site needs them.
          </p>
        </div>
      </div>

      <.form
        for={%{}}
        as={:customise}
        id="embed-customisation-form"
        phx-change="update_customisation"
        phx-target={@myself}
        class="grid grid-cols-1 md:grid-cols-3 gap-4"
      >
        <%!-- Layout --%>
        <.input
          type="select"
          id="embed-layout"
          name="customise[layout]"
          label="Layout"
          options={[
            {"Column — wide canvas, fills the container (recommended)", "column"},
            {"Default — centred with a ~640px cap (standalone-style)", "default"}
          ]}
          value={@embed_layout}
        >
          <:description>Column adapts to any container width. Default centres the booker — useful when you want a self-contained card inside a wide page.</:description>
        </.input>

        <%!-- Initial height --%>
        <.input
          type="number"
          id="embed-initial-height"
          name="customise[initial_height]"
          label="Initial height (px)"
          min="200"
          max="2000"
          step="50"
          placeholder="400"
          value={@initial_height}
          phx-debounce="blur"
        >
          <:description>Placeholder shown before the iframe auto-resizes. Inline only.</:description>
        </.input>

        <%!-- Max width --%>
        <.input
          type="number"
          id="embed-max-width"
          name="customise[max_width]"
          label="Max width (px)"
          min="200"
          max="2000"
          step="50"
          placeholder="1000"
          value={@max_width}
          phx-debounce="blur"
        >
          <:description>Container max-width. Modal popup defaults to 1000px.</:description>
        </.input>
      </.form>
    </div>
    """
  end

  # Internal component for an individual embed option card.
  slot :preview, required: true
  slot :code, required: true
  slot :footer_info, required: true
  attr :type, :string, required: true
  attr :selected, :boolean, default: false
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :badge, :string, default: nil
  attr :badge_class, :string, default: nil
  attr :myself, :any, required: true

  defp embed_option_card(assigns) do
    ~H"""
    <div
      class={["embed-option-card cursor-pointer group relative", @selected && "border-turquoise-500 shadow-md"]}
      phx-click="select_embed_type"
      phx-value-type={@type}
      phx-target={@myself}
      data-selected={to_string(@selected)}
    >
      <div :if={@selected} class="absolute -top-3 -right-3 w-8 h-8 bg-turquoise-600 rounded-full flex items-center justify-center text-white shadow-lg z-10">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7"></path>
        </svg>
      </div>
      <div class="p-6">
        <div class="flex items-start justify-between mb-4">
          <div>
            <h3 class="text-token-xl font-bold text-tymeslot-900"><%= @title %></h3>
            <p class="text-token-sm text-tymeslot-600 mt-1"><%= @description %></p>
          </div>
          <span :if={@badge} class={["px-3 py-1 text-token-xs font-semibold rounded-full", @badge_class]}>
            <%= @badge %>
          </span>
        </div>

        <%!-- Preview --%>
        <div class="mb-4 bg-tymeslot-50 rounded-token-lg p-4 border-2 border-tymeslot-200">
          <%= render_slot(@preview) %>
        </div>

        <%!-- Code Snippet --%>
        <div class="relative">
          <pre class="bg-tymeslot-900 text-tymeslot-100 rounded-token-lg p-4 pr-20 text-token-xs whitespace-pre-wrap break-all"><code class="block"><%= @code |> render_slot() |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary() |> String.split("\n") |> Enum.map_join("\n", &String.trim/1) |> String.trim() |> Phoenix.HTML.raw() %></code></pre>
          <button
            type="button"
            phx-click="copy_code"
            phx-value-type={@type}
            phx-target={@myself}
            class="absolute top-2 right-2 px-3 py-1 bg-turquoise-600 hover:bg-turquoise-700 text-white text-token-xs font-semibold rounded transition-colors"
          >
            Copy
          </button>
        </div>

        <div class="mt-4 flex items-start space-x-2 text-token-xs text-tymeslot-700">
          <svg class="w-4 h-4 text-turquoise-600 shrink-0 mt-0.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
          </svg>
          <span class="flex-1"><%= render_slot(@footer_info) %></span>
        </div>
      </div>
    </div>
    """
  end
end
