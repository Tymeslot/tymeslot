defmodule TymeslotWeb.Dashboard.PaymentLiveComponent do
  @moduledoc """
  Payment management component for the dashboard.

  This component provides a placeholder interface for upcoming Stripe payment integration,
  showing users what payment features will be available once implemented.
  """

  use TymeslotWeb, :live_component
  alias TymeslotWeb.Components.DashboardComponents

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <DashboardComponents.section_header icon={:credit_card} title="Payment Management" />

      <div class="space-y-6">
        <!-- Coming Soon Notice -->
        <div class="card-glass">
          <div class="flex items-center space-x-4">
            <div class="flex-shrink-0">
              <div class="bg-blue-500/10 rounded-xl p-3">
                <svg class="h-6 w-6 text-blue-500" fill="currentColor" viewBox="0 0 20 20">
                  <path
                    fill-rule="evenodd"
                    d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
                    clip-rule="evenodd"
                  />
                </svg>
              </div>
            </div>
            <div>
              <h3 class="text-xl font-semibold text-gray-800">Payment Features Coming Soon</h3>
              <p class="text-base text-gray-600 mt-1">
                We're integrating Stripe to enable secure payment processing for your meetings
              </p>
            </div>
          </div>
        </div>
        
    <!-- Features Grid -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-6">
          <!-- Planned Features -->
          <div class="card-glass">
            <div class="flex items-center mb-4">
              <div class="bg-teal-500/10 rounded-lg p-2 mr-3">
                <svg
                  class="h-5 w-5 text-teal-600"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-3 7h3m-3 4h3m-6-4h.01M9 16h.01"
                  />
                </svg>
              </div>
              <h4 class="text-xl font-semibold text-gray-800">Planned Features</h4>
            </div>

            <ul class="space-y-4">
              <li class="flex items-start">
                <svg
                  class="h-5 w-5 text-teal-500 mt-1 mr-3 flex-shrink-0"
                  fill="currentColor"
                  viewBox="0 0 20 20"
                >
                  <path
                    fill-rule="evenodd"
                    d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                    clip-rule="evenodd"
                  />
                </svg>
                <div>
                  <p class="text-base font-medium text-gray-700">Custom Pricing</p>
                  <p class="text-sm text-gray-600 mt-0.5">
                    Set different prices for each meeting type
                  </p>
                </div>
              </li>
              <li class="flex items-start">
                <svg
                  class="h-5 w-5 text-teal-500 mt-1 mr-3 flex-shrink-0"
                  fill="currentColor"
                  viewBox="0 0 20 20"
                >
                  <path
                    fill-rule="evenodd"
                    d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                    clip-rule="evenodd"
                  />
                </svg>
                <div>
                  <p class="text-base font-medium text-gray-700">Pre-meeting Payments</p>
                  <p class="text-sm text-gray-600 mt-0.5">
                    Require payment before confirming bookings
                  </p>
                </div>
              </li>
              <li class="flex items-start">
                <svg
                  class="h-5 w-5 text-teal-500 mt-1 mr-3 flex-shrink-0"
                  fill="currentColor"
                  viewBox="0 0 20 20"
                >
                  <path
                    fill-rule="evenodd"
                    d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                    clip-rule="evenodd"
                  />
                </svg>
                <div>
                  <p class="text-base font-medium text-gray-700">Automatic Refunds</p>
                  <p class="text-sm text-gray-600 mt-0.5">Process refunds for cancelled meetings</p>
                </div>
              </li>
              <li class="flex items-start">
                <svg
                  class="h-5 w-5 text-teal-500 mt-1 mr-3 flex-shrink-0"
                  fill="currentColor"
                  viewBox="0 0 20 20"
                >
                  <path
                    fill-rule="evenodd"
                    d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
                    clip-rule="evenodd"
                  />
                </svg>
                <div>
                  <p class="text-base font-medium text-gray-700">Revenue Analytics</p>
                  <p class="text-sm text-gray-600 mt-0.5">Track earnings and generate reports</p>
                </div>
              </li>
            </ul>
          </div>
          
    <!-- Stripe Benefits -->
          <div class="card-glass">
            <div class="flex items-center mb-4">
              <div class="bg-purple-500/10 rounded-lg p-2 mr-3">
                <svg
                  class="h-5 w-5 text-purple-600"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M9 12l2 2 4-4m5.618-4.016A11.955 11.955 0 0112 2.944a11.955 11.955 0 01-8.618 3.04A12.02 12.02 0 003 9c0 5.591 3.824 10.29 9 11.622 5.176-1.332 9-6.03 9-11.622 0-1.042-.133-2.052-.382-3.016z"
                  />
                </svg>
              </div>
              <h4 class="text-xl font-semibold text-gray-800">Why Stripe?</h4>
            </div>

            <ul class="space-y-4">
              <li class="flex items-start">
                <svg
                  class="h-5 w-5 text-purple-500 mt-1 mr-3 flex-shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M13 10V3L4 14h7v7l9-11h-7z"
                  />
                </svg>
                <div>
                  <p class="text-base font-medium text-gray-700">Enterprise Security</p>
                  <p class="text-sm text-gray-600 mt-0.5">
                    PCI-compliant with advanced fraud protection
                  </p>
                </div>
              </li>
              <li class="flex items-start">
                <svg
                  class="h-5 w-5 text-purple-500 mt-1 mr-3 flex-shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M3.055 11H5a2 2 0 012 2v1a2 2 0 002 2 2 2 0 012 2v2.945M8 3.935V5.5A2.5 2.5 0 0010.5 8h.5a2 2 0 012 2 2 2 0 104 0 2 2 0 012-2h1.064M15 20.488V18a2 2 0 012-2h3.064M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
                </svg>
                <div>
                  <p class="text-base font-medium text-gray-700">Global Payments</p>
                  <p class="text-sm text-gray-600 mt-0.5">
                    135+ currencies and local payment methods
                  </p>
                </div>
              </li>
              <li class="flex items-start">
                <svg
                  class="h-5 w-5 text-purple-500 mt-1 mr-3 flex-shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M9 19v-6a2 2 0 00-2-2H5a2 2 0 00-2 2v6a2 2 0 002 2h2a2 2 0 002-2zm0 0V9a2 2 0 012-2h2a2 2 0 012 2v10m-6 0a2 2 0 002 2h2a2 2 0 002-2m0 0V5a2 2 0 012-2h2a2 2 0 012 2v14a2 2 0 01-2 2h-2a2 2 0 01-2-2z"
                  />
                </svg>
                <div>
                  <p class="text-base font-medium text-gray-700">Financial Reporting</p>
                  <p class="text-sm text-gray-600 mt-0.5">Detailed analytics and tax documentation</p>
                </div>
              </li>
              <li class="flex items-start">
                <svg
                  class="h-5 w-5 text-purple-500 mt-1 mr-3 flex-shrink-0"
                  fill="none"
                  stroke="currentColor"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M12 8c-1.657 0-3 .895-3 2s1.343 2 3 2 3 .895 3 2-1.343 2-3 2m0-8c1.11 0 2.08.402 2.599 1M12 8V7m0 1v8m0 0v1m0-1c-1.11 0-2.08-.402-2.599-1"
                  />
                </svg>
                <div>
                  <p class="text-base font-medium text-gray-700">Instant Payouts</p>
                  <p class="text-sm text-gray-600 mt-0.5">Fast transfers to your bank account</p>
                </div>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
