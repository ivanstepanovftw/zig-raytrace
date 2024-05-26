// Based on https://github.com/ssloy/tinyraytracer.

const std = @import("std");
const jpeg = @import("jpeg_writer.zig");

const multi_threaded = true;

const width = 1024;
const height = 768;
const fov: f32 = std.math.pi / 3.0;
const out_filename = "out.jpg";
const out_quality = 100;

fn vec3(x: f32, y: f32, z: f32) Vec3f {
    return Vec3f{ .x = x, .y = y, .z = z };
}

const Vec3f = Vec3(f32);

fn Vec3(comptime T: type) type {
    return struct {
        const Self = @This();

        x: T,
        y: T,
        z: T,

        fn mul(u: Self, v: Self) T {
            return u.x * v.x + u.y * v.y + u.z * v.z;
        }

        fn mulScalar(u: Self, k: T) Self {
            return vec3(u.x * k, u.y * k, u.z * k);
        }

        fn add(u: Self, v: Self) Self {
            return vec3(u.x + v.x, u.y + v.y, u.z + v.z);
        }

        fn sub(u: Self, v: Self) Self {
            return vec3(u.x - v.x, u.y - v.y, u.z - v.z);
        }

        fn negate(u: Self) Self {
            return vec3(-u.x, -u.y, -u.z);
        }

        fn norm(u: Self) T {
            return std.math.sqrt(u.x * u.x + u.y * u.y + u.z * u.z);
        }

        fn normalize(u: Self) Self {
            return u.mulScalar(1 / u.norm());
        }

        fn cross(u: Vec3f, v: Vec3f) Vec3f {
            return vec3(
                u.y * v.z - u.z * v.y,
                u.z * v.x - u.x * v.z,
                u.x * v.y - u.y * v.x,
            );
        }
    };
}

const Light = struct {
    position: Vec3f,
    intensity: f32,
};

const Material = struct {
    refractive_index: f32,
    albedo: [4]f32,
    diffuse_color: Vec3f,
    specular_exponent: f32,

    pub fn default() Material {
        return Material{
            .refractive_index = 1,
            .albedo = [_]f32{ 1, 0, 0, 0 },
            .diffuse_color = vec3(0, 0, 0),
            .specular_exponent = 0,
        };
    }
};

const Sphere = struct {
    center: Vec3f,
    radius: f32,
    material: Material,

    fn rayIntersect(self: Sphere, origin: Vec3f, direction: Vec3f, t0: *f32) bool {
        const l = self.center.sub(origin);
        const tca = l.mul(direction);
        const d2 = l.mul(l) - tca * tca;

        if (d2 > self.radius * self.radius) {
            return false;
        }

        const thc = std.math.sqrt(self.radius * self.radius - d2);
        t0.* = tca - thc;
        const t1 = tca + thc;
        if (t0.* < 0) t0.* = t1;
        return t0.* >= 0;
    }
};

fn reflect(i: Vec3f, normal: Vec3f) Vec3f {
    return i.sub(normal.mulScalar(2).mulScalar(i.mul(normal)));
}

fn refract(i: Vec3f, normal: Vec3f, refractive_index: f32) Vec3f {
    var cosi = -@max(-1, @min(1, i.mul(normal)));
    var etai: f32 = 1;
    var etat = refractive_index;

    var n = normal;
    if (cosi < 0) {
        cosi = -cosi;
        std.mem.swap(f32, &etai, &etat);
        n = normal.negate();
    }

    const eta = etai / etat;
    const k = 1 - eta * eta * (1 - cosi * cosi);
    return if (k < 0) vec3(0, 0, 0) else i.mulScalar(eta).add(n.mulScalar(eta * cosi - std.math.sqrt(k)));
}

fn sceneIntersect(origin: Vec3f, direction: Vec3f, spheres: []const Sphere, hit: *Vec3f, normal: *Vec3f, material: *Material) bool {
    var spheres_dist: f32 = std.math.floatMax(f32);
    for (spheres) |s| {
        var dist_i: f32 = undefined;
        if (s.rayIntersect(origin, direction, &dist_i) and dist_i < spheres_dist) {
            spheres_dist = dist_i;
            hit.* = origin.add(direction.mulScalar(dist_i));
            normal.* = hit.sub(s.center).normalize();
            material.* = s.material;
        }
    }

    // Floor plane
    var checkerboard_dist: f32 = std.math.floatMax(f32);
    if (@abs(direction.y) > 1e-3) {
        const d = -(origin.y + 4) / direction.y;
        const pt = origin.add(direction.mulScalar(d));
        if (d > 0 and @abs(pt.x) < 10 and pt.z < -10 and pt.z > -30 and d < spheres_dist) {
            checkerboard_dist = d;
            hit.* = pt;
            normal.* = vec3(0, 1, 0);

            // const diffuse = @as(i32, 0.5 * hit.x + 1000) + @as(i32, 0.5 * hit.z);
            const diffuse = @as(i32, @intFromFloat(0.5 * hit.x)) + 1000 + @as(i32, @intFromFloat(0.5 * hit.z));
            const diffuse_color = if (@mod(diffuse, 2) == 1) vec3(1, 1, 1) else vec3(1, 0.7, 0.3);
            material.diffuse_color = diffuse_color.mulScalar(0.3);
        }
    }

    return @min(spheres_dist, checkerboard_dist) < 1000;
}

fn castRay(origin: Vec3f, direction: Vec3f, spheres: []const Sphere, lights: []const Light, depth: i32) Vec3f {
    var point: Vec3f = undefined;
    var normal: Vec3f = undefined;
    var material = Material.default();

    if (depth > 4 or !sceneIntersect(origin, direction, spheres, &point, &normal, &material)) {
        return vec3(0.2, 0.7, 0.8); // Background color
    }

    const reflect_dir = reflect(direction, normal).normalize();
    const refract_dir = refract(direction, normal, material.refractive_index).normalize();

    const nn = normal.mulScalar(1e-3);
    const reflect_origin = if (reflect_dir.mul(normal) < 0) point.sub(nn) else point.add(nn);
    const refract_origin = if (refract_dir.mul(normal) < 0) point.sub(nn) else point.add(nn);

    const reflect_color = castRay(reflect_origin, reflect_dir, spheres, lights, depth + 1);
    const refract_color = castRay(refract_origin, refract_dir, spheres, lights, depth + 1);

    var diffuse_light_intensity: f32 = 0;
    var specular_light_intensity: f32 = 0;

    for (lights) |l| {
        const light_dir = l.position.sub(point).normalize();
        const light_distance = l.position.sub(point).norm();

        const shadow_origin = if (light_dir.mul(normal) < 0) point.sub(nn) else point.add(nn);

        var shadow_pt: Vec3f = undefined;
        var shadow_n: Vec3f = undefined;
        var _unused: Material = undefined;
        if (sceneIntersect(shadow_origin, light_dir, spheres, &shadow_pt, &shadow_n, &_unused) and shadow_pt.sub(shadow_origin).norm() < light_distance) {
            continue;
        }

        diffuse_light_intensity += l.intensity * @max(0, light_dir.mul(normal));
        specular_light_intensity += std.math.pow(f32, @max(0, -reflect(light_dir.negate(), normal).mul(direction)), material.specular_exponent) * l.intensity;
    }

    const p1 = material.diffuse_color.mulScalar(diffuse_light_intensity * material.albedo[0]);
    const p2 = vec3(1, 1, 1).mulScalar(specular_light_intensity).mulScalar(material.albedo[1]);
    const p3 = reflect_color.mulScalar(material.albedo[2]);
    const p4 = refract_color.mulScalar(material.albedo[3]);
    return p1.add(p2.add(p3.add(p4)));
}

const RenderContext = struct {
    pixmap: []u8,
    start: usize,
    end: usize,
    spheres: []const Sphere,
    lights: []const Light,
};

fn renderFramebufferSegment(context: RenderContext) void {
    var j: usize = context.start;
    while (j < context.end) : (j += 1) {
        var i: usize = 0;
        while (i < width) : (i += 1) {
            const x = (2 * (@as(f32, @floatFromInt(i)) + 0.5) / width - 1) * std.math.tan(fov / 2.0) * width / height;
            const y = -(2 * (@as(f32, @floatFromInt(j)) + 0.5) / height - 1) * std.math.tan(fov / 2.0);

            const direction = vec3(x, y, -1).normalize();
            var c = castRay(vec3(0, 0, 0), direction, context.spheres, context.lights, 0);

            const max = @max(c.x, c.y, c.z);
            if (max > 1) c = c.mulScalar(1 / max);

            const T = @typeInfo(Vec3f).Struct;
            inline for (T.fields, 0..) |field, k| {
                const pixel: u8 = @intFromFloat(255 * @max(0, @min(1, @field(c, field.name))));
                context.pixmap[3 * (i + j * width) + k] = pixel;
            }
        }
    }
}

fn renderMulti(allocator: std.mem.Allocator, spheres: []const Sphere, lights: []const Light) !void {
    var pixmap = std.ArrayList(u8).init(allocator);
    defer pixmap.deinit();
    try pixmap.resize(3 * width * height);

    const cpu_count = try std.Thread.getCpuCount();
    const batch_size = height / cpu_count;

    var threads = std.ArrayList(std.Thread).init(allocator);
    defer threads.deinit();

    var j: usize = 0;
    while (j < height) : (j += batch_size) {
        const context = RenderContext{
            .pixmap = pixmap.items,
            .start = j,
            .end = j + batch_size,
            .spheres = spheres,
            .lights = lights,
        };

        try threads.append(try std.Thread.spawn(.{}, renderFramebufferSegment, .{context}));
    }

    for (threads.items) |thread| {
        thread.join();
    }

    try jpeg.writeToFile(out_filename, width, height, 3, pixmap.items, out_quality);
}

fn render(allocator: std.mem.Allocator, spheres: []const Sphere, lights: []const Light) !void {
    var pixmap = std.ArrayList(u8).init(allocator);
    defer pixmap.deinit();
    try pixmap.resize(3 * width * height);

    var j: usize = 0;
    while (j < height) : (j += 1) {
        var i: usize = 0;
        while (i < width) : (i += 1) {
            const x = (2 * (@as(f32, i) + 0.5) / width - 1) * std.math.tan(fov / 2.0) * width / height;
            const y = -(2 * (@as(f32, j) + 0.5) / height - 1) * std.math.tan(fov / 2.0);

            const direction = vec3(x, y, -1).normalize();
            var c = castRay(vec3(0, 0, 0), direction, spheres, lights, 0);

            const max = @max(c.x, c.y, c.z);
            if (max > 1) c = c.mulScalar(1 / max);

            const T = @typeInfo(Vec3f).Struct;
            inline for (T.fields, 0..) |field, k| {
                const pixel = @as(u8, 255 * @max(0, @min(1, @field(c, field.name))));
                pixmap.set(3 * (i + j * width) + k, pixel);
            }
        }
    }

    try jpeg.writeToFile(out_filename, width, height, 3, pixmap.toSliceConst(), out_quality);
}

pub fn main() !void {
    const ivory = Material{
        .refractive_index = 1.0,
        .albedo = [_]f32{ 0.6, 0.3, 0.1, 0.0 },
        .diffuse_color = vec3(0.4, 0.4, 0.3),
        .specular_exponent = 50,
    };

    const glass = Material{
        .refractive_index = 1.5,
        .albedo = [_]f32{ 0.0, 0.5, 0.1, 0.8 },
        .diffuse_color = vec3(0.6, 0.7, 0.8),
        .specular_exponent = 125,
    };

    const red_rubber = Material{
        .refractive_index = 1.0,
        .albedo = [_]f32{ 0.9, 0.1, 0.0, 0.0 },
        .diffuse_color = vec3(0.3, 0.1, 0.1),
        .specular_exponent = 10,
    };

    const mirror = Material{
        .refractive_index = 1.0,
        .albedo = [_]f32{ 0.0, 10.0, 0.8, 0.0 },
        .diffuse_color = vec3(1.0, 1.0, 1.0),
        .specular_exponent = 1425,
    };

    const spheres = [_]Sphere{
        Sphere{
            .center = vec3(-3, 0, -16),
            .radius = 1.3,
            .material = ivory,
        },
        Sphere{
            .center = vec3(3, -1.5, -12),
            .radius = 2,
            .material = glass,
        },
        Sphere{
            .center = vec3(1.5, -0.5, -18),
            .radius = 3,
            .material = red_rubber,
        },
        Sphere{
            .center = vec3(9, 5, -18),
            .radius = 3.7,
            .material = mirror,
        },
    };

    const lights = [_]Light{
        Light{
            .position = vec3(-10, 23, 20),
            .intensity = 1.1,
        },
        Light{
            .position = vec3(17, 50, -25),
            .intensity = 1.8,
        },
        Light{
            .position = vec3(30, 20, 30),
            .intensity = 1.7,
        },
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    if (multi_threaded) {
        try renderMulti(allocator, &spheres, &lights);
    } else {
        try render(allocator, &spheres, &lights);
    }
}
