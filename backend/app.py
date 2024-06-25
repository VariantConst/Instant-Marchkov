from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from playwright.async_api import Page, async_playwright, TimeoutError as PlaywrightTimeoutError
import base64
from typing import Optional, List
import logging
import time
from datetime import datetime, timedelta
import pytz
import asyncio
from playwright.async_api import Error as PlaywrightError
import re
from fastapi.middleware.cors import CORSMiddleware

# 配置日志
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')


app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Allows all origins
    allow_credentials=True,
    allow_methods=["*"],  # Allows all methods
    allow_headers=["*"],  # Allows all headers
)

class UserCredentials(BaseModel):
    username: str
    password: str
    target_time: Optional[str] = None
    is_return: bool = False


class ReservationResult(BaseModel):
    reserved_route: str
    reserved_time: str
    qr_code: str


class QRCodeResult(BaseModel):
    success: bool
    reservations: List[ReservationResult]
    message: str


data_route_urls = {
    "to_yanyuan": {
        "新校区→燕园校区": "https://wproc.pku.edu.cn/v2/reserve/reserveDetail?id=4",
        "200号校区→新校区→西二旗→肖家河→燕园校区": "https://wproc.pku.edu.cn/v2/reserve/reserveDetail?id=3",
        "200号校区→新校区→燕园校区": "https://wproc.pku.edu.cn/v2/reserve/reserveDetail?id=2"
    },
    "to_changping": {
        "燕园校区→新校区": "https://wproc.pku.edu.cn/v2/reserve/reserveDetail?id=7",
        "燕园校区→新校区→200号校区": "https://wproc.pku.edu.cn/v2/reserve/reserveDetail?id=6",
        "燕园校区→肖家河→西二旗→新校区→200号校区": "https://wproc.pku.edu.cn/v2/reserve/reserveDetail?id=5"
    }
}


async def login(context, username, password):
    try:
        page = await context.new_page()
        await page.goto("https://wproc.pku.edu.cn/v2/site/index", timeout=120000)
        logging.info("Navigated to login page")
        
        # 等待页面加载完成
        await page.wait_for_load_state("networkidle", timeout=60000)
        
        username_selector = "input[placeholder='学号/职工号/手机号']"
        password_selector = "input[placeholder='密码']"
        login_button_selector = 'input#logon_button[type="submit"][value="登录"]'
        
        await page.wait_for_selector(username_selector, state="visible", timeout=60000)
        await page.fill(username_selector, username, timeout=30000)
        logging.info("Filled username")

        await page.wait_for_selector(password_selector, state="visible", timeout=60000)
        await page.fill(password_selector, password, timeout=30000)
        logging.info("Filled password")

        await page.wait_for_selector(login_button_selector, state="visible", timeout=60000)
        await page.click(login_button_selector, timeout=30000)
        logging.info("Clicked login button")

        await page.wait_for_selector('p.name:text("班车预约")', state="visible", timeout=60000)
        logging.info("Login successful")

        await page.close()
        return True
    except PlaywrightTimeoutError as e:
        logging.error(f"Timeout during login: {str(e)}")
        raise HTTPException(status_code=504, detail=f"Login process timed out: {str(e)}")
    except Exception as e:
        logging.error(f"Error during login: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Login failed: {str(e)}")


async def get_qr_code(page, reserved_time):
    '''
    获取预约的二维码。

    参数:
    page: 页面
    reserved_time: 预约的时间str, 格式为 "%H:%M"

    返回:
    base64_data: 二维码base64编码
    reserved_route: 预约的路线名称
    reserved_time_detailed: 预约的时间str, 格式为 "%Y-%m-%d %H:%M"

    示例:
    >>> await get_qr_code(page, "12:00")
    >>> ("data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...", "新校区→燕园校区", "2024-07-01 12:00")
    '''
    try:
        await page.goto("https://wproc.pku.edu.cn/v2/matter/m_reserveTime", timeout=60000)
        await page.reload(timeout=60000)
        await page.wait_for_load_state("networkidle", timeout=60000)

        reserved_items = await page.query_selector_all(".pku_matter_list_data > li")
        for item in reserved_items:
            time_span = await item.query_selector(".content_title_top > span:nth-child(2)")
            if time_span:
                reservation_time = await time_span.inner_text()
                reservation_time = reservation_time.strip()
                _, date, t = reservation_time.split(" ")
                if date == await page.evaluate("() => new Date().toISOString().split('T')[0]") and t == reserved_time:
                    logging.info(f"找到今天的预约：{reservation_time}")
                    qrcode_span = await item.query_selector(".matter_list_data_btn a:has-text('签到二维码')")
                    if qrcode_span:
                        await qrcode_span.click(timeout=30000)
                        qrcode_canvas = await page.wait_for_selector("#rtq_main_canvas", timeout=30000)
                        base64_data = await page.evaluate("""(qrcode_canvas) => {
                            return qrcode_canvas.toDataURL('image/png');
                        }""", qrcode_canvas)
                        reservation_details = await page.wait_for_selector(".rtq_main", timeout=30000)
                        reserved_route = await (await reservation_details.query_selector("p:first-child")).inner_text()
                        reserved_route = reserved_route.strip()[1:-1]
                        reserved_time_detailed = await (await reservation_details.query_selector("p:nth-child(2)")).inner_text()
                        reserved_time_detailed = reserved_time_detailed.split("：")[1].strip()
                        logging.info("二维码获取成功")
                        return base64_data, reserved_route, reserved_time_detailed
    except PlaywrightTimeoutError as e:
        logging.error(f"二维码获取超时: {str(e)}")
        raise HTTPException(status_code=504, detail=f"二维码获取超时: {str(e)}")
        

async def get_temporary_qr_code(page, time_to_reserve, route_name):
    '''
    获取过期班车的临时二维码。

    参数:
    page: 页面
    time_to_reserve: 预约的时间str, 格式为 "%H:%M"
    route_name: 班车路线名称

    返回:
    base64_data: 二维码base64编码
    reserved_route: 预约的路线名称
    reserved_time_detailed: 预约的时间str, 格式为 "%Y-%m-%d %H:%M"
    '''
    try:
        await page.goto("https://wproc.pku.edu.cn/v2/matter/m_reserveTime", timeout=60000)
        await page.wait_for_load_state("networkidle", timeout=60000)
        await page.click("li:has-text('临时登记码')", timeout=30000)
        input_elements = await page.query_selector_all('input[placeholder="请选择"].el-input__inner')
        if len(input_elements) < 2:
            await page.reload(timeout=60000)
            await page.wait_for_load_state("networkidle", timeout=60000)
            input_elements = await page.query_selector_all('input[placeholder="请选择"].el-input__inner')

        # 选择日期
        await input_elements[0].click(timeout=30000)
        await page.click(f".el-select-dropdown__item > span:has-text('{route_name}')", timeout=30000)

        # 选择时间
        await input_elements[1].click(timeout=30000)
        # 选择最接近的时间
        time_options = await page.query_selector_all(".el-select-dropdown__item span")
        time_texts = [await option.inner_text() for option in time_options]

        # 排除班车路线
        valid_times = [
            datetime.strptime(t, "%H:%M")
            for t in time_texts
            if re.match(r'^\d{2}:\d{2}$', t)
        ]

        if not valid_times:
            raise ValueError("No valid time options found")

        time_to_reserve = datetime.strptime(time_to_reserve, "%H:%M")
        nearest_time = min(valid_times, key=lambda x: abs(x - time_to_reserve))
        nearest_time_str = nearest_time.strftime("%H:%M")
        logging.info(f"选择最接近的时间: {nearest_time_str}")

        await page.click(f".el-select-dropdown__item > span:has-text('{nearest_time_str}')", timeout=30000)

        # 保存canvas返回结果
        canvas = await page.wait_for_selector("#rtq_main_canvas", timeout=30000)
        base64_data = await page.evaluate("""(canvas) => {
            return canvas.toDataURL('image/png');
        }""", canvas)
        logging.info("临时二维码获取成功")
        return base64_data, route_name, f"{datetime.now().strftime('%Y-%m-%d')} {nearest_time}"
    except PlaywrightTimeoutError as e:
        logging.error(f"临时二维码获取超时: {str(e)}")
        raise HTTPException(status_code=504, detail=f"临时二维码获取超时: {str(e)}")

async def get_bus_time(context, route_name: str, route_url: str, target_time: str) -> tuple:
    '''
    获取应该预约的班车时间。首先检查target_time过去十分钟内是否有班车，如果有，直接返回。否则预约target_time之后最早的班车。

    参数:
    context: 浏览器窗口
    route_name: 班车路线名称
    route_url: 班车路线链接
    target_time: 目标时间str, 格式为 "%H:%M"

    返回:
    has_expired_bus: 是否有过期的班车
    time_to_reserve: 预约的时间str, 格式为 "%H:%M"
    route_name: 班车路线名称
    route_url: 班车路线链接
    page: 页面

    示例:
    >>> await get_bus_time(page, "新校区→燕园校区", "https://wproc.pku.edu.cn/v2/reserve/reserveDetail?id=4", "11:52")
    >>> (False, "12:00", "新校区→燕园校区", "https://wproc.pku.edu.cn/v2/reserve/reserveDetail?id=4", [page])
    '''
    try:
        page = await context.new_page()
        await page.goto(route_url, timeout=60000, wait_until="networkidle")
        logging.info(f"导航到{route_name}的预约页面: {route_url}")
        bus_times = await page.query_selector_all(".m_weekReserve_list > div") # 所有班车的div
        has_expired_bus = False # 是否有过期的班车
        time_to_reserve = datetime.strptime("23:59", "%H:%M")
        target_time = datetime.strptime(target_time, "%H:%M")
        
        for bus in bus_times:
            time_elem = await bus.query_selector("div:first-child") # 班车时间, 如"12:00"
            status_elem = await bus.query_selector("div:nth-child(2)") # 班车状态, 如"可预约"
            
            if time_elem and status_elem:
                t = await time_elem.inner_text()
                status = await status_elem.inner_text()
                
                logging.info(f"时间: {t}, 状态: {status}")

                # 将时间字符串转换为datetime对象
                t = datetime.strptime(t, "%H:%M")

                # 如果给定时间前十分钟内有班车
                has_expired_bus = has_expired_bus or target_time - timedelta(minutes=10) <= t <= target_time

                # 如果班车已经过期，直接返回
                if has_expired_bus:
                    time_to_reserve = t
                    break
                elif t > target_time and "可预约" in status:
                    time_to_reserve = min(time_to_reserve, t) # 选择target_time之后最早的可预约班车时间
        
        if time_to_reserve == datetime.strptime("23:59", "%H:%M"):
            logging.warning("没有可预约的班车")
            return None
        return has_expired_bus, time_to_reserve.strftime("%H:%M"), route_name, route_url, page

    except PlaywrightTimeoutError as e:
        logging.error(f"超时: {str(e)}")
        raise HTTPException(status_code=504, detail=f"超时: {str(e)}")


async def make_reservation(page, time, url):
    await page.goto(url, timeout=60000, wait_until="networkidle")
    bus_times = await page.query_selector_all(".m_weekReserve_list > div")
    
    for bus in bus_times:
        time_elem = await bus.query_selector("div:first-child")
        status_elem = await bus.query_selector("div:nth-child(2)")
        
        if time_elem and status_elem:
            t = await time_elem.inner_text()
            status = await status_elem.inner_text()
            
            if t == time and "可预约" in status:
                await bus.click(timeout=30000)
                await page.click("text= 确定预约  ", timeout=30000)
                logging.info(f"Reservation confirmed for {time}")
                return True

    logging.warning(f"Failed to make reservation for {time}")
    return False


@app.post("/get_qr_code", response_model=QRCodeResult)
async def api_get_qr_code(credentials: UserCredentials):
    async with async_playwright() as p:
        iphone_12 = p.devices['iPhone 12']
        browser = await p.chromium.launch(headless=False)
        context = await browser.new_context(**iphone_12)
        
        try:
            login_success = await login(context, credentials.username, credentials.password)
            if not login_success:
                return QRCodeResult(success=False, reservations=[], message="Failed to login")

            routes = data_route_urls["to_changping" if credentials.is_return else "to_yanyuan"]

            credentials.target_time = credentials.target_time or datetime.now().strftime("%H:%M")

            bus_info = [get_bus_time(context, route_name, route_url, credentials.target_time) for (route_name, route_url) in routes.items()]
            all_bus_info = await asyncio.gather(*bus_info)
            all_bus_info = [bus_info for bus_info in all_bus_info if bus_info]  # 去除None值
            
            # Flatten the list of available times
            has_expired_bus = any([bus_info[0] for bus_info in all_bus_info])
            logging.info(f"过去十分钟内是否有过期班车: {has_expired_bus}")
            if has_expired_bus:
                # 获取所有过期班车的临时二维码，返回api请求
                all_temporary_results = []
                for has_expired, time_to_reserve, route_name, route_url, page in all_bus_info:
                    if has_expired:
                        temporary_qr_code, _, temporary_time = await get_temporary_qr_code(page, time_to_reserve, route_name)
                        all_temporary_results.append(ReservationResult(
                            reserved_route=route_name,
                            reserved_time=temporary_time,
                            qr_code=temporary_qr_code
                        ))
                return QRCodeResult(success=True, reservations=all_temporary_results, message=f"成功获取{len(all_temporary_results)}个过期班车的临时二维码")
            else:
                # 没有过期班车，预约最早的班车
                if not all_bus_info:
                    return QRCodeResult(success=False, reservations=[], message="未找到可预约的班车时间")
                all_bus_info.sort(key=lambda x: x[1])  # 按时间排序
                _, earliest_time, route_name, route_url, page = all_bus_info[0]

                # 预约最早的班车
                reservation_success = await make_reservation(page, earliest_time, route_url)
                
                if reservation_success:
                    qr_code_result = await get_qr_code(page, earliest_time)
                    if qr_code_result:
                        qr_code, reserved_route, reserved_time_detailed = qr_code_result
                        reservation = ReservationResult(
                            reserved_route=reserved_route,
                            reserved_time=reserved_time_detailed,
                            qr_code=qr_code
                        )
                        return QRCodeResult(success=True, reservations=[reservation], message="Successfully made reservation and retrieved QR code")
                    else:
                        # If QR code retrieval fails, attempt to cancel the reservation
                        logging.warning("Failed to retrieve QR code. Attempting to cancel the reservation.")
                        return QRCodeResult(success=False, reservations=[], message="Failed to retrieve QR code. Reservation has been cancelled.")
                else:
                    return QRCodeResult(success=False, reservations=[], message="Failed to make reservation")
        except HTTPException as e:
            raise e
        except Exception as e:
            logging.error(f"Unexpected error: {str(e)}")
            raise HTTPException(status_code=500, detail=f"An unexpected error occurred: {str(e)}")
        finally:
            await browser.close()

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)