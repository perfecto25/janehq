# janehq

The JaneHQ master repo

## Installation



## Usage


by default, JaneHQ will start its UI/Console on port 8086 and its ingestion service on port 25900

To run JaneHQ on custom ports, start JaneHQ service with these shell variables


```
# JaneHQ UI/console
JANEHQ_UI_PORT=8080

# JaneHQ ingest port - where agents send their data to
JANEHQ_INGEST_PORT=25900 

# optional: days of metric history (CPU/memory/swap/load and top processes) to keep; older data is
# deleted from the database. Default 360.
JANEHQ_METRICS_RETENTION=360

# for Google OAUTH authentication
JANEHQ_BASE_URL=https://janehq.example.com
JANEHQ_GOOGLE_CLIENT_ID=<client id>.apps.googleusercontent.com
JANEHQ_GOOGLE_CLIENT_SECRET=<client secret>
# optional: only allow this Workspace domain
JANEHQ_GOOGLE_DOMAIN=example.com
```

## Documentation

- [Sign in with Google (Workspace)](docs/google-oauth.md)
- [Reset a lost superuser password](docs/reset-superuser.md)

## Development
    
    
    shards install
    sudo dnf install sqlite-devel

## Contributing

1. Fork it (<https://github.com/your-github-user/janehq/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [mreider](https://github.com/your-github-user) - creator and maintainer
