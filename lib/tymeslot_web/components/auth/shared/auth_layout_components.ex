defmodule TymeslotWeb.Shared.Auth.LayoutComponents do
  @moduledoc """
  Layout and container components for authentication pages.
  """

  use TymeslotWeb, :html

  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.Components.Auth.AuthVideoConfig
  import TymeslotWeb.Components.CoreComponents, only: [flash_group: 1]

  @spec auth_logo_header(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_logo_header(assigns) do
    assigns = assign_new(assigns, :subtitle, fn -> nil end)

    ~H"""
    <div class="flex flex-col items-center mb-8">
      <div class="mb-4 transform hover:scale-105 transition-all duration-300">
        <TymeslotWeb.Components.CoreComponents.Brand.logo mode={:full} img_class="h-10" />
      </div>
      <div class="text-center">
        <h1 class="text-2xl font-black text-tymeslot-900 tracking-tight">
          {@title}
        </h1>
        <%= if @subtitle do %>
          <p class="mt-1.5 text-tymeslot-500 font-medium max-w-sm mx-auto text-sm">
            {@subtitle}
          </p>
        <% end %>
      </div>
    </div>
    """
  end

  @spec auth_back_link(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_back_link(assigns) do
    ~H"""
    <%= if Config.logo_links_to_marketing?() do %>
      <a
        href={Config.site_home_path()}
        class="flex fixed top-6 left-6 items-center px-6 py-3 text-base font-bold bg-gradient-to-br from-turquoise-600 to-cyan-600 text-white rounded-token-2xl shadow-lg shadow-turquoise-500/20 hover:from-turquoise-700 hover:to-cyan-700 hover:-translate-y-1 hover:shadow-xl hover:shadow-turquoise-500/40 transition-glass duration-300 group z-50"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-5 w-5 mr-2 transform group-hover:-translate-x-1 transition-transform duration-200"
          viewBox="0 0 20 20"
          fill="currentColor"
        >
          <path
            fill-rule="evenodd"
            d="M9.707 16.707a1 1 0 01-1.414 0l-6-6a1 1 0 010-1.414l6-6a1 1 0 011.414 1.414L5.414 9H17a1 1 0 110 2H5.414l4.293 4.293a1 1 0 010 1.414z"
            clip-rule="evenodd"
          />
        </svg>
        Back to Website
      </a>
    <% end %>
    """
  end

  @spec auth_card(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_card(assigns) do
    ~H"""
    <div class="brand-card rounded-2xl sm:rounded-3xl shadow-xl p-5 sm:p-6 md:p-8 w-full mx-auto max-w-[36rem] sm:max-w-[40rem] overflow-hidden">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @spec auth_container(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_container(assigns) do
    ~H"""
    <div class="min-h-screen bg-tymeslot-50 flex flex-col">
      <div class="relative z-10 flex flex-col h-screen overflow-hidden">
        <.auth_back_link />
        <div class="w-full flex flex-col items-center justify-center flex-grow py-6 sm:py-8 px-3 sm:px-6 md:px-8 overflow-y-auto min-h-screen max-w-full">
          <div class="mx-auto w-full max-w-[95%] sm:max-w-[36rem] md:max-w-[40rem] lg:max-w-[44rem]">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  @spec auth_card_layout(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_card_layout(assigns) do
    assigns = assign_new(assigns, :subtitle, fn -> nil end)

    ~H"""
    <main class="min-h-screen relative overflow-hidden flex items-center justify-center p-4 sm:p-6">
      <%!-- Video Background --%>
      <div class="video-background-container" id="auth-video-container" phx-hook="AuthVideo">
        <div class="absolute inset-0 bg-gradient-to-br from-turquoise-600 to-blue-600 opacity-20"></div>
        <%= for {video_id, index} <- Enum.with_index(AuthVideoConfig.auth_video_ids(), 1) do %>
          <video
            class={"video-background-video #{if index == 1, do: "active", else: "inactive"}"}
            autoplay={index == 1}
            loop
            muted
            playsinline
            preload="metadata"
            poster={AuthVideoConfig.auth_video_poster()}
            id={video_id}
          >
            <%= for source <- AuthVideoConfig.auth_video_sources() do %>
              <source
                src={source.src}
                type={source.type}
                {if source.media, do: [media: source.media], else: []}
              />
            <% end %>
          </video>
        <% end %>
      </div>

      <%!-- Content Overlay --%>
      <div class="w-full max-w-[500px] relative z-10 animate-in fade-in zoom-in-95 duration-700">
        <.auth_back_link />
        
        <div class="auth-glass-card !max-w-none">
          <.auth_logo_header title={@title} subtitle={@subtitle} />
          
          <%= if assigns[:heading], do: render_slot(@heading) %>
          
          <%= if Map.get(assigns, :flash) do %>
            <div class="mb-6">
              <.flash_group flash={@flash} />
            </div>
          <% end %>
          
          <div class="space-y-6">
            {render_slot(@form)}
            
            <%= if assigns[:social] do %>
              <div class="relative py-2">
                <div class="absolute inset-0 flex items-center" aria-hidden="true">
                  <div class="w-full border-t border-tymeslot-100"></div>
                </div>
                <div class="relative flex justify-center text-token-2xs font-black uppercase tracking-[0.2em]">
                  <span class="bg-white px-4 text-tymeslot-400">Or continue with</span>
                </div>
              </div>
              {render_slot(@social)}
            <% end %>
          </div>
          
          <%= if assigns[:footer] do %>
            <div class="mt-8 pt-6 border-t-2 border-tymeslot-50">
              {render_slot(@footer)}
            </div>
          <% end %>
        </div>
      </div>
    </main>
    """
  end

  @spec auth_footer(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_footer(assigns) do
    assigns =
      assigns
      |> assign_new(:"phx-click", fn -> nil end)
      |> assign_new(:href, fn -> nil end)
      |> assign_new(:"phx-value-state", fn -> nil end)

    ~H"""
    <div class="text-center">
      <span class="text-sm text-tymeslot-500 font-bold">{@prompt}</span>
      <%= if assigns[:"phx-click"] do %>
        <button
          type="button"
          phx-click={assigns[:"phx-click"]}
          phx-value-state={assigns[:"phx-value-state"]}
          class="font-bold text-turquoise-600 hover:text-turquoise-700 transition-colors ml-2 bg-turquoise-50 hover:bg-turquoise-100 px-4 py-2 rounded-xl text-sm inline-block border-none cursor-pointer"
        >
          {@link_text}
        </button>
      <% else %>
        <a
          href={@href}
          class="font-bold text-turquoise-600 hover:text-turquoise-700 transition-colors ml-2 bg-turquoise-50 hover:bg-turquoise-100 px-4 py-2 rounded-xl text-sm inline-block"
        >
          {@link_text}
        </a>
      <% end %>
    </div>
    """
  end
end
