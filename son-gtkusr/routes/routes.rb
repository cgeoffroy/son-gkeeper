##
## Copyright (c) 2015 SONATA-NFV
## ALL RIGHTS RESERVED.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##     http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##
## Neither the name of the SONATA-NFV
## nor the names of its contributors may be used to endorse or promote
## products derived from this software without specific prior written
## permission.
##
## This work has been performed in the framework of the SONATA project,
## funded by the European Commission under Grant number 671517 through
## the Horizon 2020 and 5G-PPP programmes. The authors would like to
## acknowledge the contributions of their colleagues of the SONATA
## partner consortium (www.sonata-nfv.eu).

require 'json'
require 'sinatra'
require 'net/http'
require_relative '../helpers/init'


# Adapter class
class Adapter < Sinatra::Application
  # @method get_root
  # @overload get '/'
  # Get all available interfaces
  # -> Get all interfaces
  get '/' do
    headers 'Content-Type' => 'text/plain; charset=utf8'
    halt 200, interfaces_list.to_json
  end

  # @method get_log
  # @overload get '/adapter/log'
  # Returns contents of log file
  # Management method to get log file of adapter remotely
  get '/log' do
    logger.debug 'Adapter: entered GET /admin/log'
    headers 'Content-Type' => 'text/plain; charset=utf8'
    #filename = 'log/development.log'
    filename = 'log/production.log'

    # For testing purposes only
    begin
      txt = open(filename)

    rescue => err
      logger.error "Error reading log file: #{err}"
      return 500, "Error reading log file: #{err}"
    end

    halt 200, txt.read.to_s
  end

  get '/config' do
    # This endpoint returns the Keycloak public key
    logger.debug 'Adapter: entered GET /admin/config'

    begin
      keycloak_yml = YAML.load_file('config/keycloak.yml')
    rescue => err
      logger.error "Error loading config file: #{err}"
      halt 500, json_error("Error loading config file: #{err}")
    end
    halt 200, keycloak_yml.to_json
  end
end

# Adapter-Keycloak API class
class Keycloak < Sinatra::Application
  
  post '/config' do
    log_file = File.new("#{settings.root}/log/#{settings.environment}.log", 'a+')
    STDOUT.reopen(log_file)
    STDOUT.sync = true
    puts "REQUEST.IP:", request.ip.to_s
    puts "@@ADDRESS:", @@address.to_s
    begin
      keycloak_address = Resolv::Hosts.new.getaddress(ENV['KEYCLOAK_ADDRESS'])
    rescue
      keycloak_address = Resolv::DNS.new.getaddress(ENV['KEYCLOAK_ADDRESS'])
    end
    STDOUT.sync = false
    # Check if the request comes from keycloak docker.
    if request.ip.to_s !=  keycloak_address.to_s
      halt 401
    end
    if defined? @@client_secret
      halt 409, "Secret key is already defined."
    end
    
    @@client_secret = params['secret']
    get_oidc_endpoints
    get_adapter_install_json
    @@access_token = self.get_adapter_token
    halt 200
  end

  get '/public-key' do
    # This endpoint returns the Keycloak public key
    logger.debug 'Adapter: entered GET /public-key'
    keycloak_yml = YAML.load_file('config/keycloak.yml')
    unless keycloak_yml['realm_public_key']
      Keycloak.get_realm_public_key
      keycloak_yml = YAML.load_file('config/keycloak.yml')
    end

    response = {"public-key" => keycloak_yml['realm_public_key'].to_s}
    halt 200, response.to_json
  end


  post '/register/user' do
    # Return if content-type is not valid
    logger.info "Content-Type is " + request.media_type
    halt 415 unless (request.content_type == 'application/x-www-form-urlencoded' or request.content_type == 'application/json')

    # Compatibility support for form-urlencoded content-type
    case request.content_type
      when 'application/x-www-form-urlencoded'
        # Validate format
        form_encoded, errors = request.body.read
        halt 400, errors.to_json if errors

        # p "FORM PARAMS", form_encoded
        form = Hash[URI.decode_www_form(form_encoded)]
        # TODO: Validate Hash format

      else
        # Compatibility support for JSON content-type
        # Parses and validates JSON format
        form, errors = parse_json(request.body.read)
        halt 400, errors.to_json if errors
    end
    user_id = register_user(form)

    if user_id.nil?
      delete_user(form['username'])
      halt 400, json_error("User registration failed")
    end

    form['attributes']['userType'].each { |attr|
      # puts "SETTING_USER_ROLE", attr
      res = set_user_groups(attr, user_id)
      if res.nil?
        delete_user(form['username'])
        halt 400, json_error("User registration failed")
      end
      res = set_user_roles(attr, user_id)
      if res.nil?
        delete_user(form['username'])
        halt 400, json_error("User registration failed")
      end
    }
    response = {'username' => form['username'], 'userId' => user_id.to_s}
    halt 201, response.to_json
  end

  post '/register/service' do
    logger.debug 'Adapter: entered POST /register/service'
    # Return if content-type is not valid
    logger.info "Content-Type is " + request.media_type
    halt 415 unless (request.content_type == 'application/x-www-form-urlencoded' or request.content_type == 'application/json')

    # TODO: Do some validations to the serviceForm
    # Compatibility support for JSON content-type
    # Parses and validates JSON format
    parsed_form, errors = parse_json(request.body.read)
    halt 400, errors.to_json if errors

    # puts "REGISTERING NEW CLIENT"
    register_client(parsed_form)

    # puts "SETTING CLIENT ROLES"
    client_data, role_data = set_service_roles(parsed_form['clientId'])
    # puts "SETTING SERVICE ACCOUNT ROLES"
    set_service_account_roles(client_data['id'], role_data)
    halt 201
  end

  post '/login/user' do
    logger.debug 'Adapter: entered POST /login/user'
    # Return if Authorization is invalid
    halt 400 unless request.env["HTTP_AUTHORIZATION"]

    #p "@client_name", self.client_name
    #p "@client_secret", self.client_secret
    pass = request.env["HTTP_AUTHORIZATION"].split(' ').last
    plain_pass  = Base64.decode64(pass)

    # puts  "PLAIN", plain_user_pass.split(':').first
    # puts  "PLAIN", plain_user_pass.split(':').last
    username = plain_pass.split(':').first # params[:username]
    password = plain_pass.split(':').last # params[:password]

    credentials = {"type" => "password", "value" => password.to_s}
    login(username, credentials)
  end

  post '/login/service' do
    logger.debug 'Adapter: entered POST /login/service'
    # Return if Authorization is invalid
    halt 400 unless request.env["HTTP_AUTHORIZATION"]

    pass = request.env["HTTP_AUTHORIZATION"].split(' ').last
    plain_pass  = Base64.decode64(pass)

    client_id = plain_pass.split(':').first
    secret = plain_pass.split(':').last

    credentials = {"type" => "client_credentials", "value" => secret.to_s}
    login(client_id, credentials)
  end

  post '/authenticate' do
    logger.debug 'Adapter: entered POST /authenticate'
    # Return if Authorization is invalid
    halt 400 unless request.env["HTTP_AUTHORIZATION"]
    keyed_params = params

    case keyed_params[:'grant_type']
      when 'password' # -> user
        authenticate(keyed_params[:'client_id'],
                     keyed_params[:'username'],
                     keyed_params[:'password'],
                     keyed_params[:'grant_type'])


      when 'client_credentials' # -> service
        authenticate(keyed_params[:'client_id'],
                     nil,
                     keyed_params[:'client_secret'],
                     keyed_params[:'grant_type'])
      else
        json_error(400, 'Bad request')
      end
  end

  get '/authorize' do
    logger.debug 'Adapter: entered POST /authorize'
    # Return if Authorization is invalid
    halt 400 unless request.env["HTTP_AUTHORIZATION"]

    # Get authorization token
    user_token = request.env["HTTP_AUTHORIZATION"].split(' ').last
    unless user_token
      error = {"ERROR" => "Access token is not provided"}
      halt 400, error.to_json
    end

    # Check token validation
    val_res, val_code = token_validation(user_token)
    # Check token expiration
    if val_code == '200'
      result = is_active?(val_res)
      # puts "RESULT", result
      case result
        when false
          json_error(401, 'Token not active')
        else
          # continue
      end
    else
      halt 401, val_res
    end

    # Return if content-type is not valid
    log_file = File.new("#{settings.root}/log/#{settings.environment}.log", 'a+')
    STDOUT.reopen(log_file)
    STDOUT.sync = true
    puts "Content-Type is " + request.content_type
    if request.content_type
      logger.info "Content-Type is " + request.content_type
    end
    # halt 415 unless (request.content_type == 'application/x-www-form-urlencoded' or request.content_type == 'application/json')
    # We will accept both a JSON file, form-urlencoded or query type
    # Compatibility support
    case request.content_type
      when 'application/x-www-form-urlencoded'
        # Validate format
        # form_encoded, errors = request.body.read
        # halt 400, errors.to_json if errors

        # p "FORM PARAMS", form_encoded
        # form = Hash[URI.decode_www_form(form_encoded)]
        # mat
        # p "FORM", form
        # keyed_params = keyed_hash(form)
        # halt 401 unless (keyed_params[:'path'] and keyed_params[:'method'])

        # Request is a QUERY TYPE
        # Get request parameters
        puts "Input params", params
        keyed_params = keyed_hash(params)
        puts "KEYED_PARAMS", keyed_params
        # params examples: {:path=>"catalogues", :method=>"GET"}
        # Halt if 'path' and 'method' are not included
        halt 401 unless (keyed_params[:'path'] and keyed_params[:'method'])

      when 'application/json'
        # Compatibility support for JSON content-type
        # Parses and validates JSON format
        form, errors = parse_json(request.body.read)
        halt 400, errors.to_json if errors
        # p "FORM", form
        keyed_params = keyed_hash(form)
        halt 401 unless (keyed_params[:'path'] and keyed_params[:'method'])
      else
        # Request is a QUERY TYPE
        # Get request parameters
        puts "Input params", params
        keyed_params = keyed_hash(params)
        puts "KEYED_PARAMS", keyed_params
        # params examples: {:path=>"catalogues", :method=>"GET"}
        # Halt if 'path' and 'method' are not included
        halt 401 unless (keyed_params[:'path'] and keyed_params[:'method'])
        # halt 401, json_error("Invalid Content-type")
      end

    # TODO: Improve path and method parse (include it in body?)
    # puts "PATH", keyed_params[:'path']
    # puts "METHOD",keyed_params[:'method']
    # Check the provided path to the resource and the HTTP method, then build the request
    request = process_request(keyed_params[:'path'], keyed_params[:'method'])

    puts "Ready to authorize"
    # Authorization process
    authorize?(user_token, request)
    STDOUT.sync = false
  end

  post '/userinfo' do
    logger.debug 'Adapter: entered POST /userinfo'
    # Return if Authorization is invalid
    halt 400 unless request.env["HTTP_AUTHORIZATION"]

    user_token = request.env["HTTP_AUTHORIZATION"].split(' ').last
    unless user_token
      error = {"ERROR" => "Access token is not provided"}
      halt 400, error.to_json
    end

    # Validate token
    res, code = token_validation(user_token)
    if code == '200'
      result = is_active?(res)
      puts "RESULT", result
      case result
        when false
          json_error(401, 'Token not active')
        else
          # continue
      end
    else
      halt 400, res
    end

    # puts "RESULT", user_token
    user_info = userinfo(user_token)
    halt 200, user_info
  end

  post '/logout' do
    logger.debug 'Adapter: entered POST /logout'
    # Return if Authorization is invalid
    halt 400 unless request.env["HTTP_AUTHORIZATION"]

    user_token = request.env["HTTP_AUTHORIZATION"].split(' ').last
    # puts "headers", request.env["HTTP_AUTHORIZATION"]

    unless user_token
      error = {"ERROR" => "Access token is not provided"}
      halt 400, error.to_json
    end

    # Validate token
    res, code = token_validation(user_token)
    # p "res,code", res, code

    if code == '200'
      result = is_active?(res)
      # puts "RESULT", result
      case result
        when false
          json_error(401, 'Token not active')
        else
          # continue
      end
    else
      halt 400, res
    end

    # if headers['Authorization']
    #   puts "AUTHORIZATION", headers['Authorization'].split(' ').last
    # end
    # puts "RESULT", user_token

    logout(user_token, user=nil, realm=nil)
  end

  post '/refresh' do
    #TODO: OPTIONAL
    logger.debug 'Adapter: entered POST /refresh'
    # Return if Authorization is invalid
    # halt 400 unless request.env["HTTP_AUTHORIZATION"]
    # puts "headers", request.env["HTTP_CONTENT_DISPOSITION"]
    att = request.env['HTTP_CONTENT_DISPOSITION']
    custom_header_value = request.env['HTTP_CUSTOM_HEADER']

    # p "ATT", att
    # p "CUSTOM", custom_header_value
  end

  get '/users' do
    # This endpoint allows queries for the next fields:
    # search, lastName, firstName, email, username, first, max
    logger.debug 'Adapter: entered POST /users'
    # Return if Authorization is invalid
    halt 400 unless request.env["HTTP_AUTHORIZATION"]
    queriables = %w(search lastName firstName email username first max)

    keyed_params = params

    keyed_params.each { |k, v|
      unless queriables.include? k
        json_error(400, 'Bad query')
      end
    }
    get_users(keyed_params)
  end

  get '/services' do
    # This endpoint allows queries for the next fields:
    # name
    logger.debug 'Adapter: entered POST /services'
    # Return if Authorization is invalid
    halt 400 unless request.env["HTTP_AUTHORIZATION"]
    queriables = %w(name first max)

    keyed_params = params
    keyed_params.each { |k, v|
      unless queriables.include? k
        json_error(400, 'Bad query')
      end
    }
    get_clients(keyed_params)
  end

  get '/roles' do
    #TODO: QUERIES NOT SUPPORTED -> Check alternatives!!
    # This endpoint allows queries for the next fields:
    # search, lastName, firstName, email, username, first, max
    logger.debug 'Adapter: entered POST /users'
    # Return if Authorization is invalid
    halt 400 unless request.env["HTTP_AUTHORIZATION"]
    queriables = %w(search id name description first max)
    keyed_params = params
    keyed_params.each { |k, v|
      unless queriables.include? k
        json_error(400, 'Bad query')
      end
    }
    get_realm_roles(keyed_params)
  end
end
