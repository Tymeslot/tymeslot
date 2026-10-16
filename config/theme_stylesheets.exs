# The booking-page theme stylesheets to build, as sorted keys ("quill",
# "rhythm"): one per directory under assets/css/scheduling/themes/ holding a
# theme.css. Each is a Catalog key, and the layout loads its output as
# /assets/scheduling-theme-<key>.css.
#
# config/config.exs (the Tailwind profiles), config/dev.exs (the watchers) and
# mix.exs (the assets.build and assets.minify aliases) all evaluate this file,
# so a theme's CSS directory is its whole build configuration.
#
# The Docker images evaluate mix.exs and config/ in a dependency stage that
# has not copied assets/ yet. There this returns [], which is harmless: that
# stage builds no assets, and every later mix run sees the full tree. Keep
# the file name clear of the .dockerignore patterns (test_*.exs, check_*.exs,
# debug_*.exs, fetch_*.exs).
"../assets/css/scheduling/themes/*/theme.css"
|> Path.expand(__DIR__)
|> Path.wildcard()
|> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
|> Enum.sort()
