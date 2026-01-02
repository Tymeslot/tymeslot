defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.ErrorComponent do
  @moduledoc """
  Quill theme error component for scheduling page readiness issues.
  """
  use TymeslotWeb, :live_component

  alias TymeslotWeb.Components.CoreComponents

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container flex-1 flex flex-col items-center justify-center py-12 px-4">
      <div class="w-full max-w-xl">
        <CoreComponents.glass_morphism_card>
          <div class="p-6 md:p-8">
            <CoreComponents.icon_badge>
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 9v2m0 4h.01M4.93 4.93l14.14 14.14M12 2a10 10 0 100 20 10 10 0 000-20z"
              />
            </CoreComponents.icon_badge>
            <h1 class="text-2xl md:text-3xl font-bold mb-4" style="color: white;">
              We can’t show this scheduling page yet
            </h1>
            <CoreComponents.info_box variant={:error}>
              {@message}
            </CoreComponents.info_box>
            <p class="text-sm" style="color: rgba(255,255,255,0.85);">
              If you are the organizer, please connect a calendar in your dashboard.
            </p>
          </div>
        </CoreComponents.glass_morphism_card>
      </div>
    </div>
    """
  end
end
