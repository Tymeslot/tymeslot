defmodule TymeslotWeb.Shared.Auth.LayoutComponents do
  @moduledoc """
  Layout and container components for authentication pages.
  """

  use TymeslotWeb, :html

  alias Tymeslot.Deployment
  alias TymeslotWeb.Components.Auth.AuthVideoConfig

  @spec auth_logo_header(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_logo_header(assigns) do
    assigns = assign_new(assigns, :subtitle, fn -> nil end)

    ~H"""
    <div class="flex items-center gap-2 sm:gap-3 mb-4 sm:mb-5 md:mb-6">
      <img
        src="/images/brand/favicon.svg"
        alt="App Logo"
        class="w-6 h-6 sm:w-8 sm:h-8 md:w-10 md:h-10 transition-transform duration-300 ease-in-out hover:scale-110 hover:rotate-3"
      />
      <div>
        <h1 class="text-lg sm:text-xl md:text-2xl font-extrabold text-transparent bg-clip-text bg-gradient-to-r from-purple-600 to-cyan-500 font-heading tracking-tight">
          {@title}
        </h1>
        <%= if @subtitle do %>
          <p class="mt-0.5 sm:mt-1 text-xs sm:text-sm text-gray-700 line-clamp-2 sm:line-clamp-none">
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
    <%= if Deployment.main?() do %>
      <a
        href="/"
        class="hidden sm:flex fixed top-4 left-4 items-center px-3 py-2 text-sm font-medium bg-white/80 backdrop-blur-sm rounded-lg hover:bg-white transition duration-300 ease-in-out group z-10"
      >
        <svg
          xmlns="http://www.w3.org/2000/svg"
          class="h-[1.25rem] w-[1.25rem] mr-1 transform group-hover:-translate-x-1 transition-transform duration-200"
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
    <div class="glass-card-base rounded-2xl sm:rounded-3xl shadow-xl p-5 sm:p-6 md:p-8 w-full mx-auto max-w-[36rem] sm:max-w-[40rem] overflow-hidden">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @spec auth_container(map()) :: Phoenix.LiveView.Rendered.t()
  def auth_container(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50 flex flex-col">
      <div class="relative z-1 flex flex-col h-screen overflow-hidden">
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
    <main class="glass-theme">
      <!-- Enhanced Video Background with Crossfade Support -->
      <div class="video-background-container" id="auth-video-container">
        <%= for {video_id, index} <- Enum.with_index(AuthVideoConfig.auth_video_ids(), 1) do %>
          <video
            class={"video-background-video #{if index == 1, do: "active", else: "inactive"}"}
            autoplay={index == 1}
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
            <!-- Fallback gradient background -->
            <div class="absolute inset-0 bg-gradient-to-br from-purple-900 via-blue-900 to-indigo-900">
            </div>
          </video>
        <% end %>
      </div>

      <div class="glass-container">
        <.auth_back_link />
        <div class="flex-1 flex items-center justify-center py-4 sm:py-6 md:py-8 px-4">
          <div class="glass-card-base">
            <.auth_logo_header title={@title} subtitle={@subtitle} />
            {if assigns[:heading], do: render_slot(@heading)}
            <%= if Map.get(assigns, :flash) do %>
              <div class="mb-4">
                <.flash_group flash={@flash} />
              </div>
            <% end %>
            {render_slot(@form)}
            {if assigns[:social], do: render_slot(@social)}
            {if assigns[:footer], do: render_slot(@footer)}
          </div>
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
    <div class="text-center pt-3 sm:pt-4 mt-4 sm:mt-6 border-t border-gray-200">
      <span class="text-xs sm:text-sm text-gray-700">{@prompt}</span>
      <%= if assigns[:"phx-click"] do %>
        <button
          type="button"
          phx-click={assigns[:"phx-click"]}
          phx-value-state={assigns[:"phx-value-state"]}
          class="font-semibold text-purple-600 hover:text-purple-700 transition duration-300 ease-in-out ml-1 bg-purple-50 hover:bg-purple-100 px-3 py-1 sm:py-1.5 rounded-full text-xs sm:text-sm inline-block border-none cursor-pointer"
        >
          {@link_text}
        </button>
      <% else %>
        <a
          href={@href}
          class="font-semibold text-purple-600 hover:text-purple-700 transition duration-300 ease-in-out ml-1 bg-purple-50 hover:bg-purple-100 px-3 py-1 sm:py-1.5 rounded-full text-xs sm:text-sm inline-block"
        >
          {@link_text}
        </a>
      <% end %>
    </div>
    """
  end
end
