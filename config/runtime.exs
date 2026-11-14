import Config

# Configuración para publicar la interfaz web en un servidor (MIX_ENV=prod).
# En desarrollo y pruebas se usa lo que está en config.exs.
if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "Falta la variable de entorno SECRET_KEY_BASE (genere una con: mix phx.gen.secret)"

  config :emergencias, EmergenciasWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")],
    url: [host: System.get_env("PHX_HOST") || "localhost", port: 443, scheme: "https"],
    secret_key_base: secret_key_base

  if directorio = System.get_env("DIRECTORIO_DATOS") do
    config :emergencias, directorio_datos: directorio
  end
end
