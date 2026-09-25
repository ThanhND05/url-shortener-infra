terraform {
  backend "gcs" {
    bucket = "urlshortener-509008-tfstate"
    prefix = "url-shortener/dev"
  }
}
