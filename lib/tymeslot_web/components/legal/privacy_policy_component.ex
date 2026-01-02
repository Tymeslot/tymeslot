defmodule TymeslotWeb.Legal.PrivacyPolicyComponent do
  @moduledoc """
  LiveView component that renders the privacy policy page with information
  about data collection, usage, sharing, and user rights.
  """
  use TymeslotWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <h1 class="text-4xl font-bold text-gray-900 mb-8 text-center bg-gradient-to-r from-purple-600 to-indigo-600 bg-clip-text text-transparent">
        Privacy Policy
      </h1>

      <div class="prose prose-lg max-w-none">
        <p class="text-gray-700 mb-6">
          Last updated: 25th September 2025
        </p>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">1. Introduction</h2>
          <p class="text-gray-700 leading-relaxed">
            Tymeslot is an open-source meeting scheduling platform operated as a cloud-based SaaS service.
            This Privacy Policy explains how we collect, use, disclose, and safeguard your information
            when you use our service, in compliance with the EU General Data Protection Regulation (GDPR)
            and applicable data protection laws.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">2. Information We Collect</h2>
          <h3 class="text-xl font-semibold turquoise-accent mb-3 mt-6">Personal Information</h3>
          <p class="text-gray-700 leading-relaxed mb-3">
            When you create an account or book a meeting, we collect:
          </p>
          <ul class="list-disc pl-6 space-y-2 text-gray-700">
            <li>Your name and contact information</li>
            <li>Email address</li>
            <li>Profile information and preferences</li>
            <li>Meeting details and notes</li>
            <li>Timezone and scheduling preferences</li>
            <li>Integration credentials (encrypted)</li>
          </ul>

          <h3 class="text-xl font-semibold turquoise-accent mb-3 mt-6">Technical Information</h3>
          <p class="text-gray-700 leading-relaxed mb-3">
            We automatically collect:
          </p>
          <ul class="list-disc pl-6 space-y-2 text-gray-700">
            <li>IP address</li>
            <li>Browser type and version</li>
            <li>Device information</li>
            <li>Usage data and analytics</li>
          </ul>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">
            3. Legal Basis and How We Use Your Information
          </h2>
          <p class="text-gray-700 leading-relaxed mb-3">
            Under GDPR, we process your personal data based on the following legal bases:
          </p>
          <ul class="list-disc pl-6 space-y-2 text-gray-700">
            <li>
              <strong>Contract performance:</strong>
              To provide scheduling services and manage your account
            </li>
            <li>
              <strong>Legitimate interest:</strong>
              To improve our service, ensure security, and prevent fraud
            </li>
            <li><strong>Consent:</strong> For optional features like marketing communications</li>
            <li><strong>Legal obligation:</strong> To comply with applicable laws and regulations</li>
          </ul>
          <p class="text-gray-700 leading-relaxed mt-4 mb-3">
            We use your information to:
          </p>
          <ul class="list-disc pl-6 space-y-2 text-gray-700">
            <li>Provide the core scheduling and calendar integration services</li>
            <li>Send transactional emails (confirmations, reminders, updates)</li>
            <li>Enable multi-provider video conferencing</li>
            <li>Maintain service security and prevent abuse</li>
            <li>Improve our open-source platform</li>
          </ul>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">4. Data Sharing and Disclosure</h2>
          <p class="text-gray-700 leading-relaxed mb-3">
            We share your information only with:
          </p>
          <ul class="list-disc pl-6 space-y-2 text-gray-700">
            <li>
              <strong class="text-gray-800">Meeting Participants:</strong>
              Your name and contact details with other meeting attendees
            </li>
            <li>
              <strong class="text-gray-800">Service Providers:</strong>
              Email services, video conferencing providers, calendar integrations
            </li>
            <li>
              <strong class="text-gray-800">Legal Requirements:</strong>
              When required by law or to protect our rights
            </li>
          </ul>
          <p class="text-gray-700 leading-relaxed mt-3">
            We never sell your personal information to third parties.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">5. Data Security</h2>
          <p class="text-gray-700 leading-relaxed">
            We implement appropriate technical and organizational measures to protect your data:
          </p>
          <ul class="list-disc pl-6 mt-3 space-y-2 text-gray-700">
            <li>Encrypted data transmission (HTTPS)</li>
            <li>Secure database storage</li>
            <li>Regular security updates</li>
            <li>Access controls and authentication</li>
            <li>Rate limiting to prevent abuse</li>
          </ul>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">6. Data Retention</h2>
          <p class="text-gray-700 leading-relaxed">
            We retain your personal information for:
          </p>
          <ul class="list-disc pl-6 mt-3 space-y-2 text-gray-700">
            <li>Active meetings: Until 30 days after the meeting date</li>
            <li>Cancelled meetings: 7 days after cancellation</li>
            <li>Email logs: 90 days</li>
            <li>Technical logs: 30 days</li>
          </ul>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">7. Your Rights Under GDPR</h2>
          <p class="text-gray-700 leading-relaxed mb-3">
            As a data subject under GDPR, you have the following rights:
          </p>
          <ul class="list-disc pl-6 space-y-2 text-gray-700">
            <li><strong>Right of access:</strong> Request copies of your personal data</li>
            <li><strong>Right to rectification:</strong> Correct inaccurate information</li>
            <li><strong>Right to erasure:</strong> Request deletion of your data</li>
            <li><strong>Right to restrict processing:</strong> Limit how we use your data</li>
            <li><strong>Right to data portability:</strong> Transfer your data to another service</li>
            <li><strong>Right to object:</strong> Object to certain types of processing</li>
            <li><strong>Right to withdraw consent:</strong> For consent-based processing</li>
          </ul>
          <p class="text-gray-700 leading-relaxed mt-3">
            To exercise these rights, please contact us using the information below.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">8. Cookies and Tracking</h2>
          <p class="text-gray-700 leading-relaxed">
            We use essential cookies to:
          </p>
          <ul class="list-disc pl-6 mt-3 space-y-2 text-gray-700">
            <li>Maintain session state</li>
            <li>Remember your timezone preference</li>
            <li>Ensure security (CSRF protection)</li>
          </ul>
          <p class="text-gray-700 leading-relaxed mt-3">
            We do not use tracking cookies or third-party analytics that compromise your privacy.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">9. International Data Transfers</h2>
          <p class="text-gray-700 leading-relaxed">
            Our service is primarily operated within the European Union. When data transfers
            outside the EU are necessary, we ensure adequate safeguards are in place,
            including Standard Contractual Clauses or adequacy decisions by the European Commission.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">10. Children's Privacy</h2>
          <p class="text-gray-700 leading-relaxed">
            Our service is not intended for children under 16 years of age (or the applicable
            age of digital consent in your jurisdiction). We do not knowingly collect personal
            information from children. If you become aware that a child has provided us with
            personal information, please contact us immediately.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">11. Open Source Transparency</h2>
          <p class="text-gray-700 leading-relaxed">
            Tymeslot is an open-source project. You can review our code, security practices,
            and data handling procedures in our public repository. This transparency allows
            for community auditing and contributes to the security and trustworthiness of our platform.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">12. Changes to This Policy</h2>
          <p class="text-gray-700 leading-relaxed">
            We may update this Privacy Policy from time to time. We will notify you of any material
            changes by posting the new policy on this page, updating the "Last updated" date,
            and where appropriate, notifying you via email.
          </p>
        </section>

        <section class="mb-8">
          <h2 class="text-2xl font-semibold text-gray-800 mb-4">13. Contact Us</h2>
          <p class="text-gray-700 leading-relaxed">
            If you have questions about this Privacy Policy, need to exercise your rights,
            or have concerns about your data, please contact us:
          </p>
          <div class="mt-3 pl-6 text-gray-700">
            <p>
              <.link href="/contact" class="turquoise-accent hover:underline">
                Contact Form
              </.link>
            </p>
          </div>
          <p class="text-gray-700 leading-relaxed mt-4">
            For GDPR compliance questions or to file a complaint with a supervisory authority,
            you may contact your local data protection authority.
          </p>
        </section>
      </div>
    </div>
    """
  end
end
