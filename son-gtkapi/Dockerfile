FROM ruby:2.2.3-slim
RUN apt-get update && \
  apt-get install -y --no-install-recommends build-essential libcurl3 libcurl3-gnutls libcurl4-openssl-dev && \
	rm -rf /var/lib/apt/lists/*
RUN mkdir -p /app
WORKDIR /app
COPY Gemfile /app
RUN bundle install
COPY . /app
EXPOSE 5000
WORKDIR /app
ENV PORT 5000
ENV CATALOGUES_URL http://catalogues:4002/catalogues/api/v2
ENV PACKAGE_MANAGEMENT_URL http://son-gtkpkg:5100
ENV SERVICE_MANAGEMENT_URL http://son-gtksrv:5300
ENV FUNCTION_MANAGEMENT_URL http://son-gtkfnct:5500
ENV VIM_MANAGEMENT_URL http://son-gtkvim:5700
ENV RECORD_MANAGEMENT_URL http://son-gtkrec:5800
ENV LICENCE_MANAGEMENT_URL http://son-gtklic:5900
ENV KPI_MANAGEMENT_URL http://son-gtkkpi:5400
ENV METRICS_URL http://son-monitor:8000/api/v1
ENV USER_MANAGEMENT_URL http://son-gtkusr:5600
ENV VALIDATOR_URL http://son-validate:5050
ENV RATE_LIMITER_URL http://son-gtkrlt:5150
CMD ["foreman", "start"]
