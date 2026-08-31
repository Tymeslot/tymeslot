defmodule Tymeslot.Announcements.Announcement do
  @moduledoc """
  In-memory representation of a single feature announcement.

  Authored in `Tymeslot.Announcements.Catalog` (and optionally a SaaS-side
  catalog registered via the `:announcement_catalogs` config).

  Dating model:

    * `published_at` gates by audience — an announcement is only shown to users
      who signed up *before* this date. New users never see news about features
      that already existed when they joined. This applies to admins too — there
      is no bypass.
    * `expires_at` gates by calendar time — past this point nobody sees it. This
      is what stops an aged entry left in the catalogue from resurfacing as fake
      "new" on a much later install. `nil` means the entry never expires.

  The CTA, when present, links to a documentation article. `cta_docs_slug`
  holds just the slug; the full URL is composed from the configurable
  `:docs_article_base_url` (see `Tymeslot.Announcements.docs_url/1`). Docs live
  outside Core (there is no `/docs` route in a standalone deployment), so CTAs
  always point at the canonical public docs rather than an internal path.
  """

  @type t :: %__MODULE__{
          key: String.t(),
          title: String.t(),
          body: String.t(),
          bullets: [String.t()],
          image_path: String.t() | nil,
          cta_label: String.t() | nil,
          cta_docs_slug: String.t() | nil,
          published_at: DateTime.t(),
          expires_at: DateTime.t() | nil
        }

  @enforce_keys [:key, :title, :body, :published_at]
  defstruct key: nil,
            title: nil,
            body: nil,
            bullets: [],
            image_path: nil,
            cta_label: nil,
            cta_docs_slug: nil,
            published_at: nil,
            expires_at: nil
end
