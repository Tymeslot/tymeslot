defmodule TymeslotWeb.Components.HeroBookingDemo do
  @moduledoc """
  A component that provides an automated, animated demo of the booking flow.
  Interprets the "Quill" theme aesthetic: deep glassmorphism, cyan accents, and refined typography.
  """
  use TymeslotWeb, :live_component

  @impl true
  def update(assigns, socket) do
    demo_date = get_demo_date()

    socket =
      socket
      |> assign(assigns)
      |> assign(:demo_date, demo_date)
      |> assign(:demo_month_year, format_month_year(demo_date))
      |> assign(:demo_full_date, format_full_date(demo_date))

    {:ok, socket}
  end

  defp get_demo_date do
    today = Date.utc_today()
    date = Date.add(today, 3)

    case Date.day_of_week(date) do
      6 -> Date.add(date, 2) # Sat -> Mon
      7 -> Date.add(date, 1) # Sun -> Mon
      _ -> date
    end
  end

  defp format_month_year(date) do
    month_name = Enum.at(~w(JANUARY FEBRUARY MARCH APRIL MAY JUNE JULY AUGUST SEPTEMBER OCTOBER NOVEMBER DECEMBER), date.month - 1)
    "#{month_name} #{date.year}"
  end

  defp format_full_date(date) do
    day_name = Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), Date.day_of_week(date) - 1)
    month_name = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), date.month - 1)
    "#{day_name}, #{month_name} #{date.day}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="scheduling-box w-full hero-preview relative overflow-hidden" style="height: 540px; border-radius: 2rem;">
      <!-- Subtle ambient glow -->
      <div class="absolute -top-32 -right-32 w-80 h-80 bg-cyan-500/10 blur-[120px] rounded-full pointer-events-none"></div>
      <div class="absolute -bottom-32 -left-32 w-80 h-80 bg-teal-500/10 blur-[120px] rounded-full pointer-events-none"></div>

      <div class="step-container flex-1 relative h-full">
        <!-- Step 1: Duration Selection -->
        <div
          class="booking-step-wrapper"
          data-preview-anim="step-with-exit"
          style="--preview-delay: 0.3s; --preview-exit-delay: 4s;"
        >
          <div class="slide-content max-w-lg mx-auto">
            <div class="flex items-center gap-3 mb-8">
              <div class="quill-indicator-dot"></div>
              <h2 class="text-xl font-bold tracking-tight text-white">Select Duration</h2>
            </div>

            <div class="space-y-4">
              <div
                class="quill-glass-card group cursor-default"
                data-preview-anim="click"
                style="--preview-delay: 1.8s;"
              >
                <div class="px-6 py-5 flex items-center gap-5">
                  <div class="w-12 h-12 rounded-2xl bg-gradient-to-br from-cyan-500/20 to-teal-500/20 flex items-center justify-center text-xl flex-shrink-0 shadow-inner">
                    🎯
                  </div>
                  <div class="flex-1 min-w-0">
                    <div class="text-white font-bold text-base tracking-tight">Discovery Call</div>
                    <div class="text-white/40 text-xs mt-1">30 minutes · Strategy session</div>
                  </div>
                  <div class="w-6 h-6 rounded-full border-2 border-cyan-500 flex items-center justify-center flex-shrink-0">
                    <div class="w-3 h-3 bg-cyan-500 rounded-full"></div>
                  </div>
                </div>
              </div>

              <div class="quill-glass-card">
                <div class="px-6 py-5 flex items-center gap-5">
                  <div class="w-12 h-12 rounded-2xl bg-white/5 flex items-center justify-center text-xl flex-shrink-0">
                    💬
                  </div>
                  <div class="flex-1 min-w-0">
                    <div class="text-white font-bold text-base tracking-tight">Quick Chat</div>
                    <div class="text-white/40 text-xs mt-1">15 minutes · Introduction</div>
                  </div>
                  <div class="w-6 h-6 rounded-full border-2 border-white/10 flex-shrink-0"></div>
                </div>
              </div>

              <div class="quill-glass-card">
                <div class="px-6 py-5 flex items-center gap-5">
                  <div class="w-12 h-12 rounded-2xl bg-white/5 flex items-center justify-center text-xl flex-shrink-0">
                    🔍
                  </div>
                  <div class="flex-1 min-w-0">
                    <div class="text-white font-bold text-base tracking-tight">Deep Dive</div>
                    <div class="text-white/40 text-xs mt-1">60 minutes · Technical audit</div>
                  </div>
                  <div class="w-6 h-6 rounded-full border-2 border-white/10 flex-shrink-0"></div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Step 2: Calendar Selection -->
        <div
          class="booking-step-wrapper"
          data-preview-anim="step-with-exit"
          style="--preview-delay: 4s; --preview-exit-delay: 7.5s;"
        >
          <div class="slide-content max-w-lg mx-auto">
            <div class="flex items-center gap-3 mb-8">
              <div class="quill-indicator-dot"></div>
              <h2 class="text-xl font-bold tracking-tight text-white">Pick a Time</h2>
            </div>

            <div class="quill-glass-card p-6 shadow-2xl">
              <div class="flex justify-between items-center mb-6">
                <h3 class="text-cyan-400 font-bold text-xs tracking-[0.2em]">{@demo_month_year}</h3>
                <div class="flex gap-2">
                  <div class="w-8 h-8 rounded-xl bg-white/5 flex items-center justify-center text-white/20 border border-white/10">
                    <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M15 19l-7-7 7-7" />
                    </svg>
                  </div>
                  <div class="w-8 h-8 rounded-xl bg-white/5 flex items-center justify-center text-white/20 border border-white/10">
                    <svg class="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2.5" d="M9 5l7 7-7 7" />
                    </svg>
                  </div>
                </div>
              </div>

              <div class="grid grid-cols-7 gap-2 mb-8">
                <%= for day <- ~w(S M T W T F S) do %>
                  <div class="text-[10px] font-black text-white/20 text-center uppercase tracking-widest">{day}</div>
                <% end %>
                <%= for i <- -3..3 do %>
                  <%
                    grid_date = Date.add(@demo_date, i)
                    is_active = i == 0
                  %>
                  <div class={[
                    "h-10 flex items-center justify-center rounded-xl text-sm font-bold transition-all duration-300",
                    if(is_active,
                      do: "bg-cyan-500 text-white shadow-lg shadow-cyan-500/40 scale-105",
                      else: "text-white/30 hover:bg-white/5")
                  ]}>
                    {grid_date.day}
                  </div>
                <% end %>
              </div>

              <div class="space-y-4">
                <div class="text-[10px] font-black text-white/30 uppercase tracking-[0.2em] px-1">
                  Available Slots
                </div>
                <div class="grid grid-cols-2 gap-3">
                  <div class="py-3 rounded-xl bg-white/5 border border-white/5 text-white/20 text-xs font-bold text-center">
                    09:00 AM
                  </div>
                  <div
                    class="py-3 rounded-xl bg-white/10 border border-white/20 text-white text-xs font-bold text-center shadow-inner"
                    data-preview-anim="click"
                    style="--preview-delay: 5.5s;"
                  >
                    11:00 AM
                  </div>
                  <div class="py-3 rounded-xl bg-white/5 border border-white/5 text-white/20 text-xs font-bold text-center">
                    02:00 PM
                  </div>
                  <div class="py-3 rounded-xl bg-white/5 border border-white/5 text-white/20 text-xs font-bold text-center">
                    04:00 PM
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <!-- Step 3: Booking Form -->
        <div
          class="booking-step-wrapper"
          data-preview-anim="step-with-exit"
          style="--preview-delay: 7.5s; --preview-exit-delay: 11.5s;"
        >
          <div class="slide-content max-w-lg mx-auto">
            <div class="flex items-center gap-3 mb-8">
              <div class="quill-indicator-dot"></div>
              <h2 class="text-xl font-bold tracking-tight text-white">Final Step</h2>
            </div>

            <div class="quill-glass-card p-6 space-y-5 shadow-2xl">
              <div class="space-y-2">
                <label class="text-[10px] font-black text-white/30 uppercase tracking-[0.2em] ml-1">
                  Your Name
                </label>
                <div class="bg-white/5 border border-white/10 rounded-2xl px-5 py-4 text-white font-semibold text-sm min-h-[56px] flex items-center">
                  <span
                    class="inline-block overflow-hidden"
                    data-preview-anim="typing"
                    style="--preview-delay: 8.5s; --typing-duration: 0.8s;"
                  >
                    Alex Thompson
                  </span>
                </div>
              </div>

              <div class="space-y-2">
                <label class="text-[10px] font-black text-white/30 uppercase tracking-[0.2em] ml-1">
                  Email Address
                </label>
                <div class="bg-white/5 border border-white/10 rounded-2xl px-5 py-4 text-white/60 font-semibold text-sm min-h-[56px] flex items-center">
                  <span
                    class="inline-block overflow-hidden"
                    data-preview-anim="typing"
                    style="--preview-delay: 9.8s; --typing-duration: 1.2s;"
                  >
                    alex@example.com
                  </span>
                </div>
              </div>

              <div
                class="quill-button-primary w-full py-4 rounded-2xl text-white text-center font-bold text-sm tracking-widest uppercase shadow-xl mt-4 cursor-default"
                data-preview-anim="click"
                style="--preview-delay: 11s;"
              >
                Confirm Booking
              </div>
            </div>
          </div>
        </div>

        <!-- Step 4: Confirmation -->
        <div
          class="booking-step-wrapper"
          data-preview-anim="step"
          style="--preview-delay: 11.5s;"
        >
          <div class="slide-content max-w-lg mx-auto text-center py-8">
            <div class="relative inline-block mb-10">
              <div class="absolute inset-0 bg-cyan-500/30 blur-2xl animate-pulse"></div>
              <div class="success-icon relative w-20 h-20 bg-gradient-to-br from-cyan-400 to-teal-500 rounded-3xl flex items-center justify-center shadow-2xl" style="transform: rotate(3deg);">
                <svg class="w-8 h-8 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="3" d="M5 13l4 4L19 7" />
                </svg>
              </div>
            </div>

            <h2 class="text-3xl font-black text-white mb-2 tracking-tight">Confirmed!</h2>
            <p class="text-cyan-400 font-bold text-sm mb-8 tracking-wide">You're on the calendar</p>

            <div class="quill-glass-card p-6 text-left border-l-4 border-l-cyan-500 shadow-2xl">
              <div class="space-y-5">
                <div class="flex items-center gap-4">
                  <div class="w-12 h-12 rounded-xl bg-white/5 flex items-center justify-center text-xl">🎯</div>
                  <div class="flex-1 min-w-0">
                    <div class="text-[10px] text-white/30 font-black uppercase tracking-widest">Meeting Type</div>
                    <div class="text-white font-bold text-base mt-0.5">Discovery Call</div>
                  </div>
                </div>
                <div class="flex items-center gap-4">
                  <div class="w-12 h-12 rounded-xl bg-white/5 flex items-center justify-center text-xl">📅</div>
                  <div class="flex-1 min-w-0">
                    <div class="text-[10px] text-white/30 font-black uppercase tracking-widest">Schedule</div>
                    <div class="text-white font-bold text-base mt-0.5">{@demo_full_date} at 11:00 AM</div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
