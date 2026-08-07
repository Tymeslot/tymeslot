defmodule TymeslotWeb.Dashboard.Automation.WebhookDocumentation do
  @moduledoc """
  UI component for the webhook integration documentation section.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  @spec webhook_documentation(map()) :: Phoenix.LiveView.Rendered.t()
  def webhook_documentation(assigns) do
    ~H"""
    <div class="card-glass space-y-8">
      <div class="flex items-start gap-4">
        <div class="p-3 bg-linear-to-br from-turquoise-500 to-cyan-500 rounded-2xl shadow-lg shadow-turquoise-500/20">
          <svg class="w-8 h-8 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 6.253v13m0-13C10.832 5.477 9.246 5 7.5 5S4.168 5.477 3 6.253v13C4.168 18.477 5.754 18 7.5 18s3.332.477 4.5 1.253m0-13C13.168 5.477 14.754 5 16.5 5c1.747 0 3.332.477 4.5 1.253v13C19.832 18.477 18.247 18 16.5 18c-1.746 0-3.332.477-4.5 1.253"
            />
          </svg>
        </div>
        <div class="flex-1">
          <h3 class="text-token-2xl font-black text-tymeslot-900 tracking-tight">
            {dgettext("dashboard_automation", "Webhook Integration Guide")}
          </h3>
          <p class="text-token-sm text-tymeslot-600 font-medium mt-1">
            {dgettext(
              "dashboard_automation",
              "Connect Tymeslot to n8n, Zapier, Make, or your custom automation workflows"
            )}
          </p>
        </div>
      </div>

      <div class="space-y-6">
        <%!-- What are webhooks --%>
        <div class="p-5 bg-linear-to-br from-turquoise-50 to-cyan-50 rounded-token-2xl border-2 border-turquoise-100">
          <div class="flex items-start gap-3 mb-3">
            <div class="w-2 h-2 rounded-full bg-turquoise-500 animate-pulse mt-1.5"></div>
            <h4 class="text-token-lg font-black text-tymeslot-900">
              {dgettext("dashboard_automation", "What are webhooks?")}
            </h4>
          </div>
          <p class="text-tymeslot-700 font-medium ml-5">
            {dgettext(
              "dashboard_automation",
              "Webhooks send real-time HTTP POST notifications to your automation tools whenever booking events occur. Perfect for triggering automated workflows, sending custom emails, syncing data, or building integrations."
            )}
          </p>
        </div>

        <%!-- Quick Setup --%>
        <div>
          <div class="flex items-start gap-3 mb-4">
            <div class="w-2 h-2 rounded-full bg-turquoise-500 animate-pulse mt-1.5"></div>
            <h4 class="text-token-lg font-black text-tymeslot-900">
              {dgettext("dashboard_automation", "Quick Setup with n8n")}
            </h4>
          </div>
          <div class="grid grid-cols-1 md:grid-cols-2 gap-3 ml-5">
            <%= for {step, step_index} <- Enum.with_index([
              {dgettext("dashboard_automation", "Create a workflow"),
               dgettext("dashboard_automation", "Start a new workflow in your n8n instance")},
              {dgettext("dashboard_automation", "Add webhook trigger"),
               dgettext("dashboard_automation", "Insert a Webhook node and copy its URL")},
              {dgettext("dashboard_automation", "Configure in Tymeslot"),
               dgettext("dashboard_automation", "Create a webhook above and paste the URL")},
              {dgettext("dashboard_automation", "Select events"),
               dgettext("dashboard_automation", "Choose which booking events to monitor")},
              {dgettext("dashboard_automation", "Test connection"),
               dgettext("dashboard_automation", "Verify the webhook is working correctly")},
              {dgettext("dashboard_automation", "Build automation"),
               dgettext("dashboard_automation", "Add actions to process the webhook data")}
            ], 1) do %>
              <div class="flex items-start gap-3 p-3 bg-white rounded-token-xl border-2 border-tymeslot-100 hover:border-turquoise-200 transition-all">
                <div class="shrink-0 w-6 h-6 rounded-full bg-linear-to-br from-turquoise-500 to-cyan-500 text-white flex items-center justify-center text-xs font-black">
                  {step_index}
                </div>
                <div class="flex-1 min-w-0">
                  <div class="font-black text-tymeslot-900 text-token-sm">{elem(step, 0)}</div>
                  <div class="text-tymeslot-600 text-token-xs font-medium">{elem(step, 1)}</div>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Available Events --%>
        <div>
          <div class="flex items-start gap-3 mb-4">
            <div class="w-2 h-2 rounded-full bg-turquoise-500 animate-pulse mt-1.5"></div>
            <h4 class="text-token-lg font-black text-tymeslot-900">
              {dgettext("dashboard_automation", "Available Events")}
            </h4>
          </div>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-3 ml-5">
            <%= for {event, icon_path} <- [
              {"meeting.created", "M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"},
              {"meeting.cancelled", "M6 18L18 6M6 6l12 12"},
              {"meeting.rescheduled", "M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"}
            ] do %>
              <div class="p-4 bg-white rounded-token-xl border-2 border-tymeslot-100 hover:border-turquoise-200 hover:shadow-md transition-all">
                <div class="flex items-center gap-2 mb-2">
                  <div class="p-1.5 bg-turquoise-50 rounded-lg">
                    <svg
                      class="w-4 h-4 text-turquoise-600"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d={icon_path}
                      />
                    </svg>
                  </div>
                  <code class="text-token-sm font-black text-tymeslot-900">{event}</code>
                </div>
                <p class="text-token-xs text-tymeslot-600 font-medium">
                  <%= case event do %>
                    <% "meeting.created" -> %>
                      {dgettext(
                        "dashboard_automation",
                        "Triggers when a new booking is successfully created"
                      )}
                    <% "meeting.cancelled" -> %>
                      {dgettext(
                        "dashboard_automation",
                        "Triggers when an existing booking is cancelled"
                      )}
                    <% "meeting.rescheduled" -> %>
                      {dgettext("dashboard_automation", "Triggers when a booking time is changed")}
                  <% end %>
                </p>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Security --%>
        <div>
          <div class="flex items-start gap-3 mb-4">
            <div class="w-2 h-2 rounded-full bg-turquoise-500 animate-pulse mt-1.5"></div>
            <h4 class="text-token-lg font-black text-tymeslot-900">
              {dgettext("dashboard_automation", "Security & Authentication")}
            </h4>
          </div>
          <div class="ml-5 space-y-3">
            <div class="p-4 bg-tymeslot-50 rounded-token-xl border-2 border-tymeslot-100">
              <div class="flex items-start gap-3">
                <div class="p-2 bg-white rounded-lg shrink-0">
                  <svg
                    class="w-5 h-5 text-turquoise-600"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z"
                    />
                  </svg>
                </div>
                <div class="flex-1">
                  <p class="text-tymeslot-700 font-medium mb-2">
                    {dgettext(
                      "dashboard_automation",
                      "All webhook requests include a unique security token in the HTTP headers for verification:"
                    )}
                  </p>
                  <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
                    <div class="flex items-center gap-2 p-2 bg-white rounded-lg">
                      <code class="text-token-xs font-black text-turquoise-700 bg-turquoise-50 px-2 py-1 rounded">
                        X-Tymeslot-Token
                      </code>
                      <span class="text-token-xs text-tymeslot-600 font-medium">
                        {dgettext("dashboard_automation", "Security token")}
                      </span>
                    </div>
                    <div class="flex items-center gap-2 p-2 bg-white rounded-lg">
                      <code class="text-token-xs font-black text-turquoise-700 bg-turquoise-50 px-2 py-1 rounded">
                        X-Tymeslot-Timestamp
                      </code>
                      <span class="text-token-xs text-tymeslot-600 font-medium">
                        {dgettext("dashboard_automation", "Request timestamp")}
                      </span>
                    </div>
                  </div>
                  <p class="text-tymeslot-600 text-token-xs font-medium mt-2">
                    {dgettext(
                      "dashboard_automation",
                      "Verify the token in your automation tool to ensure requests are from Tymeslot."
                    )}
                  </p>
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
