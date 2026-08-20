from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.common.action_chains import ActionChains
import time
import json

# 1. Configurar el "Navegador Invisible"
chrome_options = Options()
chrome_options.add_argument("--headless")
chrome_options.add_argument("--no-sandbox")
chrome_options.add_argument("--disable-dev-shm-usage")
chrome_options.add_argument("--window-size=1920,1080")

driver = webdriver.Chrome(options=chrome_options)

# Tu enlace de Colab
colab_url = "https://colab.research.google.com/drive/1x9fwQ1l5NrLNcdbOINL2qioYnhwAXQN0"

try:
    print("Abriendo Google para preparar el terreno...")
    driver.get("https://google.com")
    time.sleep(3)

    # 2. Leer e inyectar el "Boleto Dorado" (cookies.json)
    print("Inyectando las cookies secretas...")
    with open('cookies.json', 'r') as file:
        cookies = json.load(file)
        for cookie in cookies:
            # Limpiamos atributos que puedan dar error en Selenium
            if 'sameSite' in cookie and cookie['sameSite'] not in ["Strict", "Lax", "None"]:
                del cookie['sameSite']
            driver.add_cookie(cookie)

    # 3. Entrar a tu Colab oficial
    print("Entrando a tu Scraper en Colab...")
    driver.get(colab_url)
    time.sleep(15) # Esperamos 15 segundos para que cargue toda la interfaz de Colab

    # 4. Simular el clic en "Run All" (Ctrl + F9)
    print("¡Presionando Ejecutar Todo (Run All)!")
    ActionChains(driver).key_down(Keys.CONTROL).send_keys(Keys.F9).key_up(Keys.CONTROL).perform()
    
    # --- NUEVA CÁMARA ESPÍA ---
    time.sleep(30) # Espera 5 segundos a ver si sale un cartel
    print("¡Tomando foto de la escena del crimen!")
    driver.save_screenshot('captura_colab.png')
    # --------------------------
    
    # 5. TIEMPO DE ESPERA VITAL
    print("Esperando a que el scraper termine su trabajo...")
    time.sleep(60) # 900 segundos (15 minutos). ¡Ajusta esto según lo que tarde tu scraper!
    print("¡Trabajo terminado, mi bro!")

except Exception as e:
    print(f"Ocurrió un error en la Matrix: {e}")
finally:
    driver.quit()
