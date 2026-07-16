defmodule TymeslotWeb.Live.Dashboard.EmbedSettings.OptionsGrid do
  @moduledoc """
  Renders the embed options grid for the dashboard.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Live.Dashboard.EmbedSettings.Helpers

  @doc """
  Renders the embed options grid.
  """
  attr :selected_embed_type, :string, required: true
  attr :username, :string, required: true
  attr :base_url, :string, required: true
  attr :booking_url, :string, required: true
  attr :embed_layout, :string, default: "column"
  attr :embed_locale, :string, default: ""
  attr :initial_height, :any, default: nil
  attr :max_width, :any, default: nil
  attr :myself, :any, required: true

  @spec options_grid(map()) :: Phoenix.LiveView.Rendered.t()
  def options_grid(assigns) do
    assigns = assign(assigns, :snippet_options, Helpers.snippet_options(assigns))

    ~H"""
    <.customise_panel
      embed_layout={@embed_layout}
      embed_locale={@embed_locale}
      initial_height={@initial_height}
      max_width={@max_width}
      myself={@myself}
    />

    <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
      <.embed_option_card
        type="inline"
        selected={@selected_embed_type == "inline"}
        title={dgettext("dashboard_embed", "Inline Embed")}
        description={dgettext("dashboard_embed", "Embed directly into your webpage")}
        badge={dgettext("dashboard_embed", "Recommended")}
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
                  <div class="text-token-xs font-semibold text-turquoise-700">
                    {dgettext("dashboard_embed", "Your booking widget here")}
                  </div>
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
          {dgettext(
            "dashboard_embed",
            "Shows the booking calendar right on your page. Copy the code and paste it into your website's HTML."
          )}
        </:footer_info>
      </.embed_option_card>

      <%!-- Popup Modal option card --%>
      <.embed_option_card
        type="popup"
        selected={@selected_embed_type == "popup"}
        title={dgettext("dashboard_embed", "Popup Modal")}
        description={dgettext("dashboard_embed", "Trigger a modal overlay with a button")}
        badge={dgettext("dashboard_embed", "Popular")}
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
                  {dgettext("dashboard_embed", "Book a Meeting →")}
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
          {dgettext(
            "dashboard_embed",
            "Visitors click a button on your page and the booking calendar opens in an overlay."
          )}
        </:footer_info>
      </.embed_option_card>

      <.embed_option_card
        type="link"
        selected={@selected_embed_type == "link"}
        title={dgettext("dashboard_embed", "Direct Link")}
        description={dgettext("dashboard_embed", "Simple link to your booking page")}
        badge={dgettext("dashboard_embed", "Easiest")}
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
                  {dgettext("dashboard_embed", "Schedule a meeting with me →")}
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
          {dgettext(
            "dashboard_embed",
            "Share this link in emails, social media bios, or messages. No code needed."
          )}
        </:footer_info>
      </.embed_option_card>

      <.embed_option_card
        type="floating"
        selected={@selected_embed_type == "floating"}
        title={dgettext("dashboard_embed", "Floating Button")}
        description={dgettext("dashboard_embed", "Fixed button in corner of page")}
        badge={dgettext("dashboard_embed", "Pro")}
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
          {dgettext(
            "dashboard_embed",
            "A floating button stays visible as visitors scroll — like a chat widget, but for booking."
          )}
        </:footer_info>
      </.embed_option_card>
    </div>

    <%!-- WordPress plugin callout. Hardcoded links: Core standalone has no /docs,
         and the plugin (on WordPress.org, source on GitHub) works against any
         instance, cloud or self-hosted. --%>
    <div class="mt-8 flex items-start gap-3 rounded-token-xl border-2 border-indigo-200 bg-linear-to-r from-indigo-50 to-blue-50 p-5">
      <svg
        class="mt-0.5 h-6 w-6 shrink-0 text-indigo-600"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.5"
        stroke="currentColor"
        aria-hidden="true"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M14.25 6.087c0-.355.186-.676.401-.959.221-.29.349-.634.349-1.003 0-1.036-1.007-1.875-2.25-1.875s-2.25.84-2.25 1.875c0 .369.128.713.349 1.003.215.283.401.604.401.959v0a.64.64 0 0 1-.657.643 48.39 48.39 0 0 1-4.163-.3c.186 1.613.293 3.25.315 4.907a.656.656 0 0 1-.658.663v0c-.355 0-.676-.186-.959-.401a1.647 1.647 0 0 0-1.003-.349c-1.036 0-1.875 1.008-1.875 2.25s.84 2.25 1.875 2.25c.369 0 .713-.128 1.003-.349.283-.215.604-.401.959-.401v0c.31 0 .555.26.532.57a48.039 48.039 0 0 1-.642 5.056c1.518.19 3.058.309 4.616.354a.64.64 0 0 0 .657-.643v0c0-.355-.186-.676-.401-.959a1.647 1.647 0 0 1-.349-1.003c0-1.035 1.008-1.875 2.25-1.875 1.243 0 2.25.84 2.25 1.875 0 .369-.128.713-.349 1.003-.215.283-.4.604-.4.959v0c0 .333.277.599.61.58a48.1 48.1 0 0 0 5.427-.63 48.05 48.05 0 0 0 .582-4.717.532.532 0 0 0-.533-.57v0c-.355 0-.676.186-.959.401-.29.221-.634.349-1.003.349-1.035 0-1.875-1.008-1.875-2.25s.84-2.25 1.875-2.25c.37 0 .713.128 1.003.349.283.215.604.401.96.401v0a.656.656 0 0 0 .658-.663 48.422 48.422 0 0 0-.37-5.36c-1.886.342-3.81.574-5.766.689a.578.578 0 0 1-.61-.58v0Z"
        />
      </svg>
      <div class="space-y-1">
        <p class="font-semibold text-indigo-900">{dgettext("dashboard_embed", "Using WordPress?")}</p>
        <p class="text-token-sm text-indigo-800">
          {dgettext(
            "dashboard_embed",
            "Install the official Tymeslot plugin to embed your booking page with a block or shortcode — no code."
          )}
          <a
            href="https://wordpress.org/plugins/tymeslot/"
            target="_blank"
            rel="noopener noreferrer"
            data-analytics-event="wordpress_plugin_cta_clicked"
            data-analytics-props={Jason.encode!(%{source_page: "embed_settings"})}
            class="font-bold text-indigo-700 underline hover:text-indigo-900"
          >
            {dgettext("dashboard_embed", "Get it on WordPress.org")}
          </a>
          <span class="text-indigo-400" aria-hidden="true">·</span>
          <a
            href="https://github.com/Tymeslot/tymeslot-wordpress"
            target="_blank"
            rel="noopener noreferrer"
            data-analytics-event="github_cta_clicked"
            data-analytics-props={Jason.encode!(%{source_page: "embed_settings"})}
            class="font-semibold text-indigo-600 underline hover:text-indigo-900"
          >
            {dgettext("dashboard_embed", "source")}
          </a>
        </p>
      </div>
    </div>

    <%!-- Hardcoded link to the cloud docs hub (slash-docs is not available in standalone Core) --%>
    <p class="mt-6 text-center text-token-sm text-tymeslot-500">
      {raw(
        dgettext(
          "dashboard_embed",
          "Need help? See the %{guide} for step-by-step instructions, platform tips, and customization options.",
          guide:
            ~s(<a href="https://tymeslot.app/docs/embed" target="_blank" rel="noopener noreferrer" class="text-turquoise-600 hover:text-turquoise-700 font-medium underline">) <>
              dgettext("dashboard_embed", "embedding guide") <> ~s(</a>)
        )
      )}
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
  attr :embed_locale, :string, required: true
  attr :initial_height, :any, required: true
  attr :max_width, :any, required: true
  attr :myself, :any, required: true

  defp customise_panel(assigns) do
    ~H"""
    <div class="mb-6 bg-white border-2 border-tymeslot-200 rounded-token-lg p-6">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h3 class="text-token-lg font-bold text-tymeslot-900">{dgettext("dashboard_embed", "Customise")}</h3>
          <p class="text-token-sm text-tymeslot-600 mt-1">
            {dgettext(
              "dashboard_embed",
              "Updates every snippet below. Defaults work for most embeds — adjust when your site needs them."
            )}
          </p>
        </div>
      </div>

      <.form
        for={%{}}
        as={:customise}
        id="embed-customisation-form"
        phx-change="update_customisation"
        phx-target={@myself}
        class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4"
      >
        <%!-- Layout --%>
        <.input
          type="select"
          id="embed-layout"
          name="customise[layout]"
          label={dgettext("dashboard_embed", "Layout")}
          options={[
            {dgettext("dashboard_embed", "Column - wide canvas, fills the container (recommended)"),
             "column"},
            {dgettext("dashboard_embed", "Default - centred with a ~640px cap (standalone-style)"),
             "default"}
          ]}
          value={@embed_layout}
        >
          <:description>
            {dgettext(
              "dashboard_embed",
              "Column adapts to any container width. Default centres the booker — useful when you want a self-contained card inside a wide page."
            )}
          </:description>
        </.input>

        <%!-- Language --%>
        <.input
          type="select"
          id="embed-language"
          name="customise[locale]"
          label={dgettext("dashboard_embed", "Language")}
          options={[
            {dgettext("dashboard_embed", "Auto - visitor's browser"), ""}
            | Helpers.language_options()
          ]}
          value={@embed_locale}
        >
          <:description>
            {dgettext(
              "dashboard_embed",
              "Language for the booking page. Auto follows each visitor's browser preference."
            )}
          </:description>
        </.input>

        <%!-- Initial height --%>
        <.input
          type="number"
          id="embed-initial-height"
          name="customise[initial_height]"
          label={dgettext("dashboard_embed", "Initial height (px)")}
          min="200"
          max="2000"
          step="50"
          placeholder="400"
          value={@initial_height}
          phx-debounce="blur"
        >
          <:description>
            {dgettext(
              "dashboard_embed",
              "Placeholder shown before the iframe auto-resizes. Inline only."
            )}
          </:description>
        </.input>

        <%!-- Max width --%>
        <.input
          type="number"
          id="embed-max-width"
          name="customise[max_width]"
          label={dgettext("dashboard_embed", "Max width (px)")}
          min="200"
          max="2000"
          step="50"
          placeholder="1000"
          value={@max_width}
          phx-debounce="blur"
        >
          <:description>
            {dgettext("dashboard_embed", "Container max-width. Modal popup defaults to 1000px.")}
          </:description>
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
            {dgettext("dashboard_embed", "Copy")}
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
