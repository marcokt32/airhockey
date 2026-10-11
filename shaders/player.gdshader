shader_type canvas_item;

uniform float target_hue : hint_range(0.0, 1.0) = 0.0;     // O matiz central que quer mudar (0.0 é Vermelho)
uniform float hue_tolerance : hint_range(0.0, 0.5) = 0.1; // Largura do espectro/faixa de cor que será afetada
uniform float hue_shift : hint_range(-0.5, 0.5) = 0.3;   // O quanto você quer girar essa cor no espectro

// Função auxiliar para converter RGB para HSV
vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));

    float d = q.x - min(q.w, q.y);
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
}

// Função auxiliar para converter HSV de volta para RGB
vec3 hsv2rgb(vec3 c) {
    vec4 K = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    vec3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
}

void fragment() {
    vec4 current_color = texture(TEXTURE, UV);
    
    // Converte o pixel atual para HSV
    vec3 hsv = rgb2hsv(current_color.rgb);
    
    // Calcula a distância circular no espectro de Matiz (Hue vai de 0 a 1)
    float hue_diff = abs(hsv.x - target_hue);
    if (hue_diff > 0.5) {
        hue_diff = 1.0 - hue_diff;
    }
    
    // Se o pixel estiver dentro do espectro/faixa selecionada, altera o Matiz
    if (hue_diff <= hue_tolerance) {
        hsv.x = fract(hsv.x + hue_shift);
        COLOR = vec4(hsv2rgb(hsv), current_color.a);
    } else {
        COLOR = current_color;
    }
}
