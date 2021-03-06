#==============================================================================#
# AWSCore.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


__precompile__()


module AWSCore


export AWSException, AWSConfig, aws_config, AWSRequest, post_request, do_request


using Retry
using SymDict
using XMLDict


# For compatibility with Julia 0.4
using Compat: read, readstring


include("http.jl")
include("AWSException.jl")
include("AWSCredentials.jl")
include("names.jl")
include("mime.jl")



#------------------------------------------------------------------------------#
# Configuration.
#------------------------------------------------------------------------------#


function aws_config(;creds=AWSCredentials(),
                     region=get(ENV, "AWS_DEFAULT_REGION", "us-east-1"),
                     args...)
    @SymDict(creds, region, args...)
end

aws_user_arn(aws) = aws_user_arn(aws[:creds])
aws_account_number(aws) = aws_account_number(aws[:creds])



#------------------------------------------------------------------------------#
# AWSRequest to Request.jl conversion.
#------------------------------------------------------------------------------#


typealias AWSRequest SymbolDict


# Construct a HTTP POST request dictionary for "servce" and "query"...
#
# e.g.
# aws = Dict(:creds  => AWSCredentials(),
#            :region => "ap-southeast-2")
#
# post_request(aws, "sdb", "2009-04-15", StrDict("Action" => "ListDomains"))
#
# Dict{Symbol, Any}(
#     :creds    => creds::AWSCredentials
#     :verb     => "POST"
#     :url      => "http://sdb.ap-southeast-2.amazonaws.com/"
#     :headers  => Dict("Content-Type" =>
#                       "application/x-www-form-urlencoded; charset=utf-8)
#     :content  => "Version=2009-04-15&ContentType=JSON&Action=ListDomains"
#     :resource => "/"
#     :region   => "ap-southeast-2"
#     :service  => "sdb"
# )

function post_request(aws::AWSRequest,
                      service::ASCIIString,
                      version::ASCIIString,
                      query::Dict)

    resource = get(aws, :resource, "/")
    url = aws_endpoint(service, aws[:region]) * resource
    if version != ""
        query["Version"] = version
    end
    headers = Dict("Content-Type" =>
                   "application/x-www-form-urlencoded; charset=utf-8")
    content = format_query_str(query)

    @SymDict(verb = "POST", service, resource, url, headers, query, content,
             aws...)
end


# Convert AWSRequest dictionary into Requests.Request (Requests.jl)

function Request(r::AWSRequest)
    Request(r[:verb], r[:resource], r[:headers], r[:content], URI(r[:url]))
end


# Call http_request for AWSRequest.

function http_request(request::AWSRequest, args...)
    http_request(Request(request), get(request, :return_stream, false))
end


# Pretty-print AWSRequest dictionary.

function dump_aws_request(r::AWSRequest)

    action = r[:verb]
    name = r[:resource]
    if haskey(r, :query) && haskey(r[:query], "Action")
        action = r[:query]["Action"]
    end
    if haskey(r, :query)
        for k in keys(r[:query])
            if ismatch(r"Name$", k)
                name *= " "
                name *= r[:query][k]
            end
        end
    end
    println("$(r[:service]).$action $name")
end



#------------------------------------------------------------------------------#
# AWSRequest retry loop
#------------------------------------------------------------------------------#


include("sign.jl")


function do_request(r::AWSRequest)

    # Try request 3 times to deal with possible Redirect and ExiredToken...
    @repeat 3 try

        # Default headers...
        if !haskey(r, :headers)
            r[:headers] = Dict()
        end
        r[:headers]["User-Agent"] = "JuliaAWS.jl/0.0.0"
        r[:headers]["Host"]       = URI(r[:url]).host

        # Load local system credentials if needed...
        if !haskey(r, :creds) || r[:creds].token == "ExpiredToken"
            r[:creds] = AWSCredentials()
        end

        # Use credentials to sign request...
        sign!(r)

        if debug_level > 0
            dump_aws_request(r)
        end

        # Send the request...
        response = http_request(r)

    catch e

        # Handle HTTP Redirect...
        @retry if http_status(e) in [301, 302, 307] &&
                  haskey(headers(e), "Location")
            r[:url] = headers(e)["Location"]
        end

        e = AWSException(e)

        # Handle ExpiredToken...
        @retry if typeof(e) == ExpiredToken
            r[:creds].token = "ExpiredToken"
        end
        if debug_level > 0
            println("Warning: AWSCore.do_request() exception: $(typeof(e))")
        end
    end

    # If there is reponse data check for (and parse) XML or JSON...
    if typeof(response) == Response && length(response.data) > 0

        mime = get(mimetype(response))

        if ismatch(r"/xml$", mime)
            response =  parse_xml(bytestring(response))
        end

        if ismatch(r"/x-amz-json-1.0$", mime)
            response = JSON.parse(bytestring(response))
        end

        if ismatch(r"json$", mime)
            response = JSON.parse(bytestring(response))
            @protected try 
                action = r[:query]["Action"]
                response = response[action * "Response"]
                response = response[action * "Result"]
            catch e
                @ignore if typeof(e) == KeyError end
            end
        end
    end

    return response
end


global debug_level = 0

function set_debug_level(n)
    global debug_level = n
end



end # module AWSCore


#==============================================================================#
# End of file.
#==============================================================================#
