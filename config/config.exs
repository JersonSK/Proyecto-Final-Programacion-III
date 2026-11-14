import Config

# Carpeta donde se guardan los archivos de texto plano (relativa a la raíz del proyecto).
config :emergencias,
  directorio_datos: "datos",
  # Cantidad mínima por debajo de la cual un recurso se considera crítico.
  umbral_critico: 10,
  # Puntaje mínimo (0-100) para considerar dos reportes de mascotas como posible coincidencia.
  umbral_coincidencia: 60

# ---------------------------------------------------------------------------
# Interfaz web (Phoenix + LiveView). Corre dentro del nodo servidor.
# ---------------------------------------------------------------------------
config :emergencias, EmergenciasWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  # 0.0.0.0: también se puede abrir desde otros equipos o celulares de la misma red.
  http: [ip: {0, 0, 0, 0}, port: 4000],
  url: [host: "localhost"],
  server: true,
  # Solo para desarrollo; en producción se toma de la variable SECRET_KEY_BASE (runtime.exs).
  secret_key_base: "sYk3Qh0m2Jv9nZ1xWc7rTq5bLp8dFg4uEa6iOy2sHk9mNw3vXz0cRb5tUj7lPe1q",
  live_view: [signing_salt: "Jt7wQe2kLm9x"],
  pubsub_server: Emergencias.PubSub,
  render_errors: [formats: [html: EmergenciasWeb.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason

if config_env() == :test do
  config :emergencias, directorio_datos: Path.join(System.tmp_dir!(), "emergencias_test")
  config :emergencias, EmergenciasWeb.Endpoint, http: [port: 4002], server: false
  config :logger, level: :warning
end
