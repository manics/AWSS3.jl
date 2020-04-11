aws = AWSCore.default_aws_config()
aws[:region] = "us-east-1"
bucket_name = "ocaws.jl.test." * lowercase(Dates.format(now(Dates.UTC), "yyyymmddTHHMMSSZ"))

@testset "Create Bucket" begin
    s3_create_bucket(aws, bucket_name)
    @test bucket_name in s3_list_buckets(aws)
    s3_enable_versioning(aws, bucket_name)
    sleep(1)
end

@testset "Bucket Tagging" begin
    @test isempty(s3_get_tags(aws, bucket_name))
    tags = Dict("A" => "1", "B" => "2", "C" => "3")
    s3_put_tags(aws, bucket_name, tags)
    @test s3_get_tags(aws, bucket_name) == tags
    s3_delete_tags(aws, bucket_name)
    @test isempty(s3_get_tags(aws, bucket_name))
end

@testset "Create Objects" begin
    s3_put(aws, bucket_name, "key1", "data1.v1")
    s3_put(bucket_name, "key2", "data2.v1", tags = Dict("Key" => "Value"))
    s3_put(aws, bucket_name, "key3", "data3.v1")
    s3_put(aws, bucket_name, "key3", "data3.v2")
    s3_put(aws, bucket_name, "key3", "data3.v3"; metadata = Dict("foo" => "bar"))
    s3_put(aws, bucket_name, "key4", "data3.v4"; acl="bucket-owner-full-control")
    s3_put_tags(aws, bucket_name, "key3", Dict("Left" => "Right"))

    @test isempty(s3_get_tags(aws, bucket_name, "key1"))
    @test s3_get_tags(aws, bucket_name, "key2")["Key"] == "Value"
    @test s3_get_tags(aws, bucket_name, "key3")["Left"] == "Right"
    s3_delete_tags(aws, bucket_name, "key2")
    @test isempty(s3_get_tags(aws, bucket_name, "key2"))

    @test s3_get(aws, bucket_name, "key1") == b"data1.v1"
    @test s3_get(aws, bucket_name, "key2") == b"data2.v1"
    @test s3_get(bucket_name, "key3") == b"data3.v3"
    @test s3_get(bucket_name, "key4") == b"data3.v4"
    @test s3_get_meta(bucket_name, "key3")["x-amz-meta-foo"] == "bar"

    s3_put(aws, bucket_name, "subdir/key5", "data5.v1")
    s3_put(aws, bucket_name, "subdir/key6", "data6.v1")

end

@testset "ASync Get" begin
    @sync begin
        for i in 1:2
            @async begin
                @test s3_get(bucket_name, "key3") == b"data3.v3"
                if AWSCore.debug_level > 0
                    println("success ID: $i")
                end
            end
        end
    end
end

@testset "Raw Return - XML" begin
    xml = "<?xml version='1.0'?><Doc><Text>Hello</Text></Doc>"
    s3_put(aws, bucket_name, "file.xml", xml, "text/xml")
    @test String(s3_get(aws, bucket_name, "file.xml", raw=true)) == xml
    @test s3_get(aws, bucket_name, "file.xml")["Text"] == "Hello"
end

@testset "Object Copy" begin
    s3_copy(bucket_name, "key1"; to_bucket=bucket_name, to_path="key1.copy")
    @test s3_get(aws, bucket_name, "key1.copy") == b"data1.v1"
end

@testset "Sign URL" begin
    url = s3_sign_url(aws, bucket_name, "key1")
    curl_output = ""

    @repeat 3 try
        curl_output = read(`curl -s -o - $url`, String)
    catch e
        @delay_retry if true end
    end

    @test curl_output == "data1.v1"

    fn = "/tmp/jl_qws_test_key1"
    if isfile(fn)
        rm(fn)
    end

    @repeat 3 try
        s3_get_file(aws, bucket_name, "key1", fn)
    catch e
        sleep(1)
        @retry if true end
    end

    @test read(fn, String) == "data1.v1"
    rm(fn)
end

@testset "Object exists" begin
    for key in ["key1", "key2", "key3", "key1.copy", "subdir/key5", "subdir/key6"]
        @test s3_exists(aws, bucket_name, key)
    end
end

@testset "List Objects" begin
    expectedkeys1 = ["key1", "key1.copy", "key2", "key3", "key4"]
    expectedprefixes1 = ["subdir/"]
    objects1 = collect(s3_list_objects(aws, bucket_name))
    @test expectedkeys1 == sort([o["Key"] for o in objects1 if haskey(o, "Key")])
    @test expectedprefixes1 == sort([o["Prefix"] for o in objects1 if haskey(o, "Prefix")])

    expectedkeys2 = ["key1", "key1.copy", "key2", "key3", "key4", "subdir/key5", "subdir/key6"]
    objects2 = collect(s3_list_objects(aws, bucket_name, delimiter=""))
    @test all(map(e -> haskey(e, "Key") && !haskey(e, "Prefix"), objects2))
    @test expectedkeys2 == sort([o["Key"] for o in objects2])

    expected3 = ["subdir/key5", "subdir/key6"]
    objects3 = collect(s3_list_objects(aws, bucket_name, "subdir/"))
    @test all(map(e -> haskey(e, "Key") && !haskey(e, "Prefix"), objects3))
    @test expected3 == sort([o["Key"] for o in objects3])
end

@testset "Object Delete" begin
    s3_delete(aws, bucket_name, "key1.copy")
    @test !("key1.copy" in [o["Key"] for o in s3_list_objects(aws, bucket_name) if haskey(o, "Key")])
end

@testset "Check Metadata" begin
    meta = s3_get_meta(aws, bucket_name, "key1")
    @test meta["ETag"] == "\"68bc8898af64159b72f349b391a7ae35\""
end

@testset "Check Object Versions" begin
    versions = s3_list_versions(aws, bucket_name, "key3")
    @test length(versions) == 3
    @test (s3_get(aws, bucket_name, "key3"; version=versions[3]["VersionId"]) == b"data3.v1")
    @test (s3_get(aws, bucket_name, "key3"; version=versions[2]["VersionId"]) == b"data3.v2")
    @test (s3_get(aws, bucket_name, "key3"; version=versions[1]["VersionId"]) == b"data3.v3")
end

@testset "Purge Versions" begin
    s3_purge_versions(aws, bucket_name, "key3")
    versions = s3_list_versions(aws, bucket_name, "key3")
    @test length(versions) == 1
    @test s3_get(aws, bucket_name, "key3") == b"data3.v3"
end

@testset "default Content-Type" begin
    # https://github.com/samoconnor/AWSS3.jl/issues/24
    ctype(key) = s3_get_meta(bucket_name, key)["Content-Type"]

    for k in [
        "file.foo",
        "file",
        "file_html",
        "file/html",
        "foobar.html/file.htm"]

        s3_put(aws, bucket_name, k, "x")
        @test ctype(k) == "application/octet-stream"
    end

    for (k, t) in [
        ("foo/bar/file.html",  "text/html"),
        ("x.y.z.js",           "application/javascript"),
        ("downalods/foo.pdf",  "application/pdf"),
        ("data/foo.csv",       "text/csv"),
        ("this.is.a.file.txt", "text/plain"),
        ("my.log",             "text/plain"),
        ("big.dat",            "application/octet-stream"),
        ("some.tar.gz",        "application/octet-stream"),
        ("data.bz2",           "application/octet-stream")]

        s3_put(aws, bucket_name, k, "x")
        @test ctype(k) == t
    end
end

@testset "Empty and Delete Bucket" begin
    for b in s3_list_buckets()
        if occursin(r"^ocaws.jl.test", b)
            @protected try
                @sync for v in s3_list_versions(aws, b)
                    @async s3_delete(aws, b, v["Key"]; version = v["VersionId"])
                end
                s3_delete_bucket(aws, b)
            catch e
                @ignore if isa(e, AWSCore.AWSException) && e.code == "NoSuchBucket" end
            end
        end
    end

    @test !in(bucket_name, s3_list_buckets(aws))
end

@testset "Delete Non-Existant Bucket" begin
    @test_throws AWSCore.AWSException s3_delete_bucket(aws, bucket_name)
end